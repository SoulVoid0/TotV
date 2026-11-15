"""votv-os-bridge: the host side of the TotV OS <-> Voices of the Void integration.

* publishes the real monitors to the game (screens.json) so it knows when to move
  the inventory to a second screen;
* captures the KDE PC session for the in-game laptop screen (pc-frame.json + BMPs);
* follows the game's events and decides which window the host compositor shows
  where; the KWin script (kwin/votv-os-wm) asks for that state over D-Bus
  (org.totv.VotvOS.WindowState) and binds Meta+Esc to LeavePC.
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time
from pathlib import Path

from PyQt6.QtCore import QObject, QTimer, pyqtClassInfo, pyqtSlot
from PyQt6.QtDBus import QDBusAbstractAdaptor, QDBusConnection
from PyQt6.QtGui import QGuiApplication, QImage

from . import config, paths
from .capture import NestedCapture, frame_digest
from .ipc import GameLink, write_atomic

SERVICE = "org.totv.VotvOS"
OBJECT = "/org/totv/VotvOS"


def _read_pid(path: Path) -> int:
    try:
        pid = int(path.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


class Bridge(QObject):
    def __init__(self, app: QGuiApplication):
        super().__init__()
        self.app = app
        self.rt = paths.runtime_dir()
        self.link = GameLink(self.rt)
        self.capture = NestedCapture(self.rt / "pc-session.bus")
        self.cfg = config.effective()
        self.pc_wanted = False         # the game says the player is at the PC
        self.pc_visible = False        # the KDE window covers the game
        self.inventory_open = False
        self.game_seen = 0.0
        self.seq = 0
        self.last_digest = b""
        self.cfg_mtime = 0.0
        self._pc_timer = QTimer(self, singleShot=True)
        self._pc_timer.timeout.connect(self._show_pc)

        app.screenAdded.connect(lambda *_: self.publish_screens())
        app.screenRemoved.connect(lambda *_: self.publish_screens())
        app.primaryScreenChanged.connect(lambda *_: self.publish_screens())
        self.publish_screens()

        self._events = QTimer(self, interval=40)
        self._events.timeout.connect(self.poll_events)
        self._events.start()
        self._frames = QTimer(self, interval=100)
        self._frames.timeout.connect(self.capture_tick)
        self._frames.start()
        self._last_capture = 0.0

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
            elif kind == "hello":
                # A (re)started game: it needs the screens and nothing is open.
                self.publish_screens()
                self.pc_wanted = self.inventory_open = False
                self._set_pc_visible(False)

    def _show_pc(self) -> None:
        if self.pc_wanted:
            self._set_pc_visible(True)

    def _set_pc_visible(self, visible: bool) -> None:
        if visible == self.pc_visible:
            return
        self.pc_visible = visible
        self.link.send("overlay_shown", shown=visible)

    def leave_pc(self) -> None:
        self.pc_wanted = False
        self._pc_timer.stop()
        self._set_pc_visible(False)
        self.link.send("leave_pc")

    # frames for the in-game screen ------------------------------------------------------
    def capture_tick(self) -> None:
        mtime = 0.0
        for p in (paths.SYSTEM_CONFIG, paths.user_config()):
            try:
                mtime = max(mtime, p.stat().st_mtime)
            except OSError:
                pass
        if mtime != self.cfg_mtime:
            self.cfg_mtime = mtime
            self.cfg = config.effective()
            self.link.send("config_reload")
        pc = self.cfg["pc"]
        fps = float(pc.get("ingame_fps", 2))
        if not pc.get("replace_ingame_ui", True) or fps <= 0 or self.pc_visible:
            return
        now = time.monotonic()
        if now - self._last_capture < 1.0 / fps:
            return
        self._last_capture = now
        img = self.capture.grab()
        if img is None or img.isNull():
            return
        width = int(pc.get("ingame_width", 1024))
        if img.width() > width:
            img = img.scaledToWidth(width)
        digest = frame_digest(img)
        if digest == self.last_digest:
            return
        self.last_digest = digest
        self.seq += 1
        name = f"pc-{self.seq}.bmp"
        img = img.convertToFormat(QImage.Format.Format_RGB32)
        tmp = self.rt / "frames" / f".{name}.tmp"
        if not img.save(str(tmp), "BMP"):
            return
        os.replace(tmp, self.rt / "frames" / name)
        write_atomic(self.rt / "pc-frame.json", json.dumps(
            {"seq": self.seq, "file": f"frames/{name}", "w": img.width(), "h": img.height()}).encode())
        old = self.rt / "frames" / f"pc-{self.seq - 4}.bmp"
        try:
            old.unlink()
        except FileNotFoundError:
            pass

    # window state for the KWin script ---------------------------------------------------
    def window_state(self) -> dict:
        sec = self.secondary_screen()
        mode = self.cfg["inventory"].get("second_screen", "auto")
        inv_screen = sec if mode != "off" else ""
        return {
            "primary": self.screens()[0]["name"] if self.app.screens() else "",
            "pc": {"pid": _read_pid(self.rt / "pc-session.pid"), "visible": self.pc_visible},
            "inventory": {"pid": _read_pid(self.rt / "inventory.pid"),
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
                           "inventory_open": b.inventory_open, "frames": b.seq,
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
    (paths.runtime_dir() / "bridge.pid").write_text(str(os.getpid()))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
