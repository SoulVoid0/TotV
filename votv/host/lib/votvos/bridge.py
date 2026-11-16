"""votv-os-bridge: the host side of the TotV OS <-> Voices of the Void integration.

Runs in the TotV shell (as the votv system user, next to the game) and:

* publishes the real monitors to the game (screens.json), so it knows when to move the
  inventory to a second screen;
* decides which save runs (target.json, followed by the mod): the shared Home save
  "default" at boot and while nobody is logged in, the user's own save (named after
  the user) at login; the VotV Saves app can load any other;
* follows the game's events and tells the KWin script (kwin/votv-os-wm) over D-Bus
  (org.totv.VotvOS.WindowState) which window goes where: the game, the "PC" (the
  greeter while nobody is logged in, else the user's KDE desktop) and the inventory.
  Meta+Esc calls LeavePC.

The in-game screen's frames come from whoever is the PC: the greeter draws its own
(votv-login), a user's desktop is captured by votv-pc-agent in that session.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import sys
import time
from pathlib import Path

from PyQt6.QtCore import QObject, QTimer, pyqtClassInfo, pyqtSlot
from PyQt6.QtDBus import QDBusAbstractAdaptor, QDBusConnection
from PyQt6.QtGui import QGuiApplication

from . import config, paths
from .ipc import GameLink, write_atomic
from .saves import DEFAULT, Registry, current_session_user

SERVICE = "org.totv.VotvOS"
OBJECT = "/org/totv/VotvOS"


def read_pid(path: Path) -> int:
    try:
        pid = int(path.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def totvd(request: dict, timeout: float = 30.0) -> dict:
    """One request to the TotV system helper (totvd, root) over its socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(str(paths.LOGIN_SOCKET))
            s.sendall((json.dumps(request) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf or b"{}")
    except (OSError, ValueError) as e:
        return {"ok": False, "error": f"the TotV system helper is not reachable ({e})"}


class Bridge(QObject):
    def __init__(self, app: QGuiApplication):
        super().__init__()
        self.app = app
        self.rt = paths.runtime_dir()
        self.link = GameLink(self.rt)
        self.reg = Registry(runtime=self.rt)
        self.cfg = config.effective()
        self.pc_wanted = False         # the game says the player is at the PC
        self.pc_visible = False        # the KDE window covers the game
        self.inventory_open = False
        self.game_seen = 0.0
        self.cfg_mtime = 0.0
        self.session_user: str | None = None
        self.session_stamp = None
        self.autologin_done = False
        self._pc_timer = QTimer(self, singleShot=True)
        self._pc_timer.timeout.connect(self._show_pc)

        app.screenAdded.connect(lambda *_: self.publish_screens())
        app.screenRemoved.connect(lambda *_: self.publish_screens())
        app.primaryScreenChanged.connect(lambda *_: self.publish_screens())
        self.publish_screens()
        self.publish_state()

        self._events = QTimer(self, interval=40)
        self._events.timeout.connect(self.poll_events)
        self._events.start()
        self._slow = QTimer(self, interval=500)
        self._slow.timeout.connect(self.slow_tick)
        self._slow.start()
        self.follow_session(force=True)

    # screens ------------------------------------------------------------------------
    def screens(self) -> list[dict]:
        prim = self.app.primaryScreen()
        out = []
        for s in self.app.screens():
            g = s.geometry()
            out.append({"name": s.name(), "x": g.x(), "y": g.y(), "w": g.width(), "h": g.height(),
                        "scale": s.devicePixelRatio(), "primary": s is prim,
                        "hz": s.refreshRate()})
        out.sort(key=lambda d: (not d["primary"], d["x"], d["y"]))
        return out

    def publish_screens(self) -> None:
        self.link.write("screens.json", {"screens": self.screens()})

    def secondary_screen(self) -> str:
        sc = self.screens()
        return sc[1]["name"] if len(sc) > 1 else ""

    def publish_state(self) -> None:
        """For the frame producers: no capture while the real desktop covers the game."""
        self.link.write("bridge-state.json", {"pc_visible": self.pc_visible, "user": self.session_user})

    # who is logged in, which save runs --------------------------------------------------
    def follow_session(self, force: bool = False) -> None:
        f = self.rt / "session.json"
        try:
            st = f.stat()
            stamp = (st.st_ino, st.st_mtime_ns)
        except OSError:
            stamp = None
        if stamp == self.session_stamp and not force:
            return
        self.session_stamp = stamp
        user = current_session_user(self.rt)
        if user == self.session_user and not force:
            return
        self.session_user = user
        sv = self.cfg["saves"]
        base = int(self.cfg["home"].get("base_mode", 1))
        self.reg.ensure_builtin(user, sv.get("user_mode", "home"), base)
        name = user or DEFAULT
        running = self.reg.running()
        # A restarted bridge keeps the save the game already runs.
        if not (force and running and running.get("name") == name):
            self.reg.load(name, None, by="login" if user else "logout")
        # Leaving the PC of the previous user.
        self.pc_wanted = False
        self._set_pc_visible(False)
        self.link.send("config_reload")
        self.publish_state()

    def maybe_autologin(self) -> None:
        if self.autologin_done or self.session_user:
            return
        self.autologin_done = True
        conf = paths.read_kv(paths.TOTV_CONF)
        if conf.get("AUTOLOGIN") == "yes":
            r = totvd({"op": "autologin"})
            if not r.get("ok"):
                print(f"votv-os-bridge: autologin: {r.get('error')}", file=sys.stderr)

    # game events --------------------------------------------------------------------
    def poll_events(self) -> None:
        for msg in self.link.poll():
            self.game_seen = time.monotonic()
            kind = msg.get("type")
            if kind == "pc_active":
                if msg.get("active"):
                    self.pc_wanted = True
                    self._pc_timer.start(int(float(msg.get("delay", 0.4)) * 1000))
                else:
                    self.pc_wanted = False
                    self._pc_timer.stop()
                    self._set_pc_visible(False)
            elif kind == "inventory":
                self.inventory_open = bool(msg.get("open"))
            elif kind == "save_loaded":
                self.reg.played(str(msg.get("name")), msg.get("slot"))
                if msg.get("name") == DEFAULT:
                    self.maybe_autologin()
            elif kind == "hello":
                # A (re)started game: it needs the screens and nothing is open.
                self.publish_screens()
                self.pc_wanted = self.inventory_open = False
                self._set_pc_visible(False)

    def slow_tick(self) -> None:
        self.follow_session()
        mtime = 0.0
        for p in (paths.SYSTEM_CONFIG, paths.user_config(self.session_user or paths.SYSTEM_USER)):
            try:
                mtime = max(mtime, p.stat().st_mtime)
            except OSError:
                pass
        if mtime != self.cfg_mtime:
            self.cfg_mtime = mtime
            self.cfg = config.effective(self.session_user)
            self.link.send("config_reload")

    def _show_pc(self) -> None:
        if self.pc_wanted:
            self._set_pc_visible(True)

    def _set_pc_visible(self, visible: bool) -> None:
        if visible == self.pc_visible:
            return
        self.pc_visible = visible
        self.link.send("overlay_shown", shown=visible)
        self.publish_state()

    def leave_pc(self) -> None:
        self.pc_wanted = False
        self._pc_timer.stop()
        self._set_pc_visible(False)
        self.link.send("leave_pc")

    # window state for the KWin script ---------------------------------------------------
    def pc_pid(self) -> int:
        if self.session_user:
            pid = read_pid(self.rt / "pc-session.pid")
            if pid:
                return pid
        return read_pid(self.rt / "greeter.pid")

    def window_state(self) -> dict:
        sec = self.secondary_screen()
        mode = self.cfg["inventory"].get("second_screen", "auto")
        inv_screen = sec if mode != "off" else ""
        return {
            "primary": self.screens()[0]["name"] if self.app.screens() else "",
            "pc": {"pid": self.pc_pid(), "visible": self.pc_visible,
                   "others": [p for p in (read_pid(self.rt / "pc-session.pid"), read_pid(self.rt / "greeter.pid"))
                              if p and p != self.pc_pid()]},
            "inventory": {"pid": read_pid(self.rt / "inventory.pid"),
                          "visible": self.inventory_open and bool(inv_screen), "screen": inv_screen},
            "game": {"classes": ["votv-win64-shipping.exe", "votv.exe", "steam_app_votv"]},
        }


@pyqtClassInfo("D-Bus Interface", SERVICE)
class Adaptor(QDBusAbstractAdaptor):
    def __init__(self, parent: "Holder"):
        super().__init__(parent)
        self.bridge = parent.bridge
        self.setAutoRelaySignals(True)

    @pyqtSlot(result=str)
    def WindowState(self) -> str:   # noqa: N802 (D-Bus naming)
        return json.dumps(self.bridge.window_state())

    @pyqtSlot()
    def LeavePC(self) -> None:      # noqa: N802
        self.bridge.leave_pc()

    @pyqtSlot(result=str)
    def Status(self) -> str:        # noqa: N802
        b = self.bridge
        return json.dumps({"pc_wanted": b.pc_wanted, "pc_visible": b.pc_visible,
                           "inventory_open": b.inventory_open, "user": b.session_user,
                           "save": b.reg.running(),
                           "game_seen_s_ago": round(time.monotonic() - b.game_seen, 1) if b.game_seen else None,
                           "screens": b.screens()})


class Holder(QObject):
    def __init__(self, bridge: Bridge):
        super().__init__()
        self.bridge = bridge
        self.adaptor = Adaptor(self)


def main() -> int:
    os.environ.setdefault("QT_QPA_PLATFORM", "wayland")
    app = QGuiApplication(sys.argv)
    app.setApplicationName("votv-os-bridge")
    app.setQuitOnLastWindowClosed(False)
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    signal.signal(signal.SIGINT, lambda *_: app.quit())
    bridge = Bridge(app)
    holder = Holder(bridge)
    bus = QDBusConnection.sessionBus()
    if not bus.registerService(SERVICE) or not bus.registerObject(OBJECT, holder):
        print("votv-os-bridge: D-Bus registration failed (already running?)", file=sys.stderr)
        return 1
    write_atomic(paths.runtime_dir() / "bridge.pid", str(os.getpid()).encode())
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
