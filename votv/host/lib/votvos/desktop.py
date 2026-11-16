"""The TotV OS apps around sessions and saves.

votv-login      (the PC while nobody is logged in; runs in the TotV shell as votv) the
                login screen of the in-game PC: pick your user, type your password
votv-saves      (KDE desktop) VotV Saves: create, rename, duplicate, delete and load saves,
                as the game's own menu did (there is no main menu on TotV OS)
votv-pc-agent   (inside a user's KDE desktop) captures the desktop for the in-game screen
votv-mods       (KDE desktop) VotV Mods: download and install Thunderstore mods into the
                r2modman profile the game loads (r2modman will not while the game runs);
                "Apply mods" restarts TotV OS so the game starts with them
votv-logout     (KDE desktop) log out: back to the shared Home save
totv-updater    (KDE desktop) TotV Update: update the OS, the game and r2modman in place
"""
from __future__ import annotations

import grp
import json
import os
import pwd
import signal
import subprocess
import sys

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFont, QGuiApplication
from PyQt6.QtWidgets import (QAbstractItemView, QApplication, QComboBox, QDialog,
                             QDialogButtonBox, QFormLayout, QHBoxLayout, QInputDialog, QLabel,
                             QLineEdit, QListWidget, QListWidgetItem, QMessageBox, QPlainTextEdit,
                             QPushButton, QSpinBox, QVBoxLayout, QWidget)

from . import config, paths
from .bridge import totvd
from .capture import FrameWriter, NestedCapture
from .ipc import write_atomic
from .saves import MODE_LABELS, MODES, Registry, SaveError, current_session_user


def login_users() -> list[str]:
    """People who can log in: regular accounts in the votv group (the installer's user and
    anyone added with totv-adduser)."""
    try:
        members = set(grp.getgrnam("votv").gr_mem)
    except KeyError:
        members = set()
    out = []
    for p in pwd.getpwall():
        if 1000 <= p.pw_uid < 60000 and (p.pw_name in members or not members) \
                and not p.pw_shell.endswith(("nologin", "false")):
            out.append(p.pw_name)
    return sorted(out)


# votv-login -------------------------------------------------------------------------------
class Greeter(QWidget):
    def __init__(self):
        super().__init__()
        self.rt = paths.runtime_dir()
        self.setWindowTitle("TotV login")
        self.setStyleSheet("QWidget { background: #0f1318; color: #e6e9ee; font-size: 18px; }"
                           "QLineEdit, QComboBox { background: #1c232c; border: 1px solid #36414e;"
                           " padding: 8px; border-radius: 6px; }"
                           "QPushButton { background: #2f6fd6; border: none; padding: 10px 24px;"
                           " border-radius: 6px; } QPushButton:disabled { background: #36414e; }")
        outer = QVBoxLayout(self)
        outer.addStretch(2)
        title = QLabel("TotV")
        title.setFont(QFont("Noto Sans", 44, QFont.Weight.Light))
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        outer.addWidget(title)
        sub = QLabel("You are home. Log in to go to your own save.")
        sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
        outer.addWidget(sub)
        box = QWidget()
        box.setMaximumWidth(460)
        form = QFormLayout(box)
        self.user = QComboBox()
        self.user.setEditable(True)
        self.user.addItems(login_users())
        default = paths.read_kv(paths.USER_CONF).get("USERNAME")
        if default:
            self.user.setCurrentText(default)
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.EchoMode.Password)
        self.password.returnPressed.connect(self.login)
        form.addRow("User", self.user)
        form.addRow("Password", self.password)
        self.go = QPushButton("Log in")
        self.go.clicked.connect(self.login)
        form.addRow(self.go)
        self.msg = QLabel("")
        self.msg.setStyleSheet("color: #f08a7a")
        form.addRow(self.msg)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(box)
        row.addStretch(1)
        outer.addLayout(row)
        outer.addStretch(3)
        write_atomic(self.rt / "greeter.pid", str(os.getpid()).encode())
        self.frames = FrameWriter(self.rt, "greeter")
        self.timer = QTimer(self, interval=250)
        self.timer.timeout.connect(self.tick)
        self.timer.start()

    def login(self) -> None:
        self.go.setEnabled(False)
        self.msg.setText("")
        QApplication.processEvents()
        r = totvd({"op": "login", "user": self.user.currentText().strip(), "password": self.password.text()})
        self.password.clear()
        self.go.setEnabled(True)
        if not r.get("ok"):
            self.msg.setText(r.get("error") or "Login failed")

    def tick(self) -> None:
        logged_in = current_session_user(self.rt) is not None
        if logged_in:
            return
        cfg = config.effective()
        fps = float(cfg["pc"].get("ingame_fps", 2))
        if cfg["pc"].get("replace_ingame_ui", True) and self.frames.due(fps):
            self.frames.write(self.grab().toImage(), int(cfg["pc"].get("ingame_width", 1024)))


def greeter_main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("votv-login")
    app.setDesktopFileName("votv-login")
    w = Greeter()
    scr = QGuiApplication.primaryScreen()
    if scr is not None:
        w.resize(scr.size())
    w.show()   # the KWin script makes it fullscreen when it is the PC
    return app.exec()


# votv-pc-agent ------------------------------------------------------------------------------
def agent_main() -> int:
    """In a user's PC desktop: frames of it for the in-game screen."""
    app = QGuiApplication(sys.argv)
    app.setApplicationName("votv-pc-agent")
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    rt = paths.runtime_dir()
    cap = NestedCapture(address=os.environ.get("DBUS_SESSION_BUS_ADDRESS", ""))
    frames = FrameWriter(rt, "desktop")
    me = paths.me()

    def tick() -> None:
        if current_session_user(rt) != me:
            return
        cfg = config.effective(me)
        pc = cfg["pc"]
        if not pc.get("replace_ingame_ui", True) or not frames.due(float(pc.get("ingame_fps", 2))):
            return
        img = cap.grab()
        if img is not None:
            frames.write(img, int(pc.get("ingame_width", 1024)))

    t = QTimer(interval=100)
    t.timeout.connect(tick)
    t.start()
    return app.exec()


# votv-saves ----------------------------------------------------------------------------------
RULE_FIELDS = [("difficulty", "Difficulty (0 easiest - 4 hardest)", 0, 4)]


class NewSave(QDialog):
    def __init__(self, parent: QWidget):
        super().__init__(parent)
        self.setWindowTitle("New save")
        form = QFormLayout(self)
        self.title = QLineEdit()
        self.title.setPlaceholderText("My station")
        self.mode = QComboBox()
        for m in MODES:
            self.mode.addItem(MODE_LABELS[m], m)
        self.mode.setToolTip("Home: the real-life clock, never hungry or tired, the power never goes out.")
        form.addRow("Name", self.title)
        form.addRow("Game mode", self.mode)
        self.rules: dict[str, QSpinBox] = {}
        for key, label, lo, hi in RULE_FIELDS:
            sp = QSpinBox()
            sp.setRange(lo, hi)
            sp.setValue(2)
            self.rules[key] = sp
            form.addRow(label, sp)
        self.extra = QLineEdit()
        self.extra.setPlaceholderText('more game rules as JSON, e.g. {"kerfurs": false}')
        form.addRow("Other rules", self.extra)
        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)

    def values(self) -> tuple[str, str, dict]:
        rules = {k: sp.value() for k, sp in self.rules.items()}
        if self.extra.text().strip():
            extra = json.loads(self.extra.text())
            if not isinstance(extra, dict):
                raise ValueError("the other rules must be a JSON object")
            rules.update(extra)
        return self.title.text(), self.mode.currentData(), rules


class Saves(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("VotV Saves")
        self.user = paths.me()
        self.reg = Registry()
        lay = QVBoxLayout(self)
        self.head = QLabel("")
        lay.addWidget(self.head)
        self.list = QListWidget()
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.list.itemDoubleClicked.connect(lambda *_: self.load())
        lay.addWidget(self.list, 1)
        row = QHBoxLayout()
        for label, fn in (("New…", self.new), ("Load", self.load), ("Rename…", self.rename),
                          ("Duplicate…", self.duplicate), ("Delete", self.delete), ("Go home", self.home)):
            b = QPushButton(label)
            b.clicked.connect(fn)
            row.addWidget(b)
        lay.addLayout(row)
        self.resize(720, 480)
        self.refresh()
        t = QTimer(self, interval=2000)
        t.timeout.connect(self.refresh)
        t.start()

    def running(self) -> str | None:
        r = self.reg.running()
        return r.get("name") if r else None

    def refresh(self) -> None:
        sel = self.selected()
        running = self.running()
        self.list.clear()
        saves = sorted(self.reg.for_user(self.user).items(),
                       key=lambda kv: (kv[0] != "default", kv[0] != self.user, -(kv[1].get("last_played") or 0)))
        for name, e in saves:
            mode = MODE_LABELS.get(e.get("mode", "home"), e.get("mode"))
            tag = "  ▶ running" if name == running else ""
            shared = "  (shared)" if e.get("owner") == "*" else ""
            it = QListWidgetItem(f"{e.get('title', name)}   —   {mode}{shared}{tag}")
            it.setData(Qt.ItemDataRole.UserRole, name)
            self.list.addItem(it)
            if name == sel:
                self.list.setCurrentItem(it)
        self.head.setText(f"Saves of {self.user}. Loading one takes you into it at once.")

    def selected(self) -> str | None:
        it = self.list.currentItem()
        return it.data(Qt.ItemDataRole.UserRole) if it else None

    def _do(self, fn, *a) -> object:
        try:
            r = fn(*a)
            self.refresh()
            return r
        except (SaveError, OSError, ValueError) as e:
            QMessageBox.warning(self, "VotV Saves", str(e))
            return None

    def new(self) -> None:
        d = NewSave(self)
        if d.exec() != QDialog.DialogCode.Accepted:
            return
        try:
            title, mode, rules = d.values()
        except ValueError as e:
            QMessageBox.warning(self, "VotV Saves", str(e))
            return
        base = int(config.effective(self.user)["home"].get("base_mode", 1))
        name = self._do(self.reg.create, self.user, title, mode, rules, base)
        if name and QMessageBox.question(self, "VotV Saves", f"Go to “{title}” now?") == QMessageBox.StandardButton.Yes:
            self._do(self.reg.load, name, self.user)

    def load(self) -> None:
        n = self.selected()
        if n:
            self._do(self.reg.load, n, self.user)

    def home(self) -> None:
        self._do(self.reg.load, self.user, self.user)

    def rename(self) -> None:
        n = self.selected()
        if not n:
            return
        e = self.reg.get(n) or {}
        t, ok = QInputDialog.getText(self, "Rename", "New name:", text=e.get("title", n))
        if ok:
            self._do(self.reg.rename, self.user, n, t)

    def duplicate(self) -> None:
        n = self.selected()
        if not n:
            return
        e = self.reg.get(n) or {}
        t, ok = QInputDialog.getText(self, "Duplicate", "Name of the copy:", text=f"{e.get('title', n)} copy")
        if ok:
            self._do(self.reg.duplicate, self.user, n, t)

    def delete(self) -> None:
        n = self.selected()
        if not n:
            return
        e = self.reg.get(n) or {}
        if QMessageBox.question(self, "Delete", f"Delete “{e.get('title', n)}”? It is moved to "
                                f"{self.reg.dir / 'deleted'}.") == QMessageBox.StandardButton.Yes:
            self._do(self.reg.delete, self.user, n, self.running())


def saves_main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("votv-saves")
    app.setDesktopFileName("votv-saves")
    w = Saves()
    w.show()
    return app.exec()


def saves_cli(argv: list[str]) -> int:
    """votv-saves list | load NAME | new TITLE MODE | home"""
    reg, user = Registry(), paths.me()
    try:
        if not argv or argv[0] == "list":
            run = reg.running() or {}
            for n, e in sorted(reg.for_user(user).items()):
                print(f"{'*' if run.get('name') == n else ' '} {n}\t{e.get('mode')}\t{e.get('title')}")
        elif argv[0] == "load" and len(argv) == 2:
            reg.load(argv[1], user)
        elif argv[0] == "home":
            reg.load(user, user)
        elif argv[0] == "new" and len(argv) == 3:
            print(reg.create(user, argv[1], argv[2]))
        else:
            print(saves_cli.__doc__, file=sys.stderr)
            return 2
    except SaveError as e:
        print(f"votv-saves: {e}", file=sys.stderr)
        return 1
    return 0


# votv-mods ------------------------------------------------------------------------------------
class Mods(QWidget):
    def __init__(self):
        super().__init__()
        from . import mods as M
        self.M = M
        self.setWindowTitle("VotV Mods")
        self.index: list[dict] = []
        lay = QVBoxLayout(self)
        self.banner = QLabel("")
        self.banner.setWordWrap(True)
        self.banner.setStyleSheet("background: #4a3a10; color: #ffe7a0; padding: 8px; border-radius: 4px;")
        lay.addWidget(self.banner)
        cols = QHBoxLayout()
        left = QVBoxLayout()
        left.addWidget(QLabel("Installed (profile: %s)" % M.profile_dir().name))
        self.inst = QListWidget()
        left.addWidget(self.inst, 1)
        rowl = QHBoxLayout()
        for label, fn in (("Remove", self.remove), ("Update all", self.update_all)):
            b = QPushButton(label)
            b.clicked.connect(fn)
            rowl.addWidget(b)
        left.addLayout(rowl)
        right = QVBoxLayout()
        self.q = QLineEdit()
        self.q.setPlaceholderText("Search Thunderstore (Voices of the Void)…")
        self.q.returnPressed.connect(self.do_search)
        right.addWidget(self.q)
        self.found = QListWidget()
        self.found.itemDoubleClicked.connect(lambda *_: self.add())
        right.addWidget(self.found, 1)
        self.desc = QLabel("")
        self.desc.setWordWrap(True)
        right.addWidget(self.desc)
        self.found.currentItemChanged.connect(self.describe)
        b = QPushButton("Install")
        b.clicked.connect(self.add)
        right.addWidget(b)
        cols.addLayout(left, 1)
        cols.addLayout(right, 2)
        lay.addLayout(cols, 1)
        row = QHBoxLayout()
        self.status = QLabel("")
        row.addWidget(self.status, 1)
        self.apply = QPushButton("Apply mods (restart TotV)")
        self.apply.setStyleSheet("font-weight: bold;")
        self.apply.clicked.connect(self.apply_mods)
        row.addWidget(self.apply)
        lay.addLayout(row)
        self.resize(1000, 640)
        self.refresh()
        QTimer.singleShot(50, self.load_index)

    def say(self, text: str) -> None:
        self.status.setText(text)
        QApplication.processEvents()

    def load_index(self) -> None:
        self.say("Loading the Thunderstore package list…")
        try:
            self.index = self.M.fetch_index()
            self.say(f"{len(self.index)} packages on Thunderstore.")
            self.do_search()
        except OSError as e:
            self.say(f"Thunderstore is not reachable: {e}")

    def refresh(self) -> None:
        self.inst.clear()
        for name, m in sorted(self.M.installed().items()):
            v = m.get("versionNumber") or {}
            tag = "  (part of TotV)" if name in self.M.BUILTIN else ""
            it = QListWidgetItem(f"{name}  {v.get('major', 0)}.{v.get('minor', 0)}.{v.get('patch', 0)}{tag}")
            it.setData(Qt.ItemDataRole.UserRole, name)
            self.inst.addItem(it)
        p = self.M.pending()
        if p.get("installed") or p.get("removed"):
            self.banner.setText("Changes waiting for a restart: "
                                + ", ".join([f"+{n}" for n in p.get("installed", [])] + [f"-{n}" for n in p.get("removed", [])])
                                + ". Press “Apply mods” to restart TotV with them.")
            self.banner.show()
        else:
            self.banner.hide()

    def do_search(self) -> None:
        self.found.clear()
        for p in self.M.search(self.index, self.q.text())[:300]:
            v = p["versions"][0]
            it = QListWidgetItem(f"{p['full_name']}  {v['version_number']}  ({sum(x.get('downloads', 0) for x in p['versions'])} downloads)")
            it.setData(Qt.ItemDataRole.UserRole, p["full_name"])
            it.setToolTip(v.get("description", ""))
            self.found.addItem(it)

    def describe(self, it, _prev=None) -> None:
        if it is None:
            return
        p = self.M.by_full_name(self.index).get(it.data(Qt.ItemDataRole.UserRole))
        if p:
            v = p["versions"][0]
            deps = ", ".join(v.get("dependencies", [])) or "none"
            self.desc.setText(f"{v.get('description', '')}\nDependencies: {deps}")

    def _run(self, fn, *a) -> None:
        try:
            fn(*a)
        except (self.M.ModError, OSError, ValueError, KeyError) as e:
            QMessageBox.warning(self, "VotV Mods", str(e))
        self.refresh()

    def add(self) -> None:
        it = self.found.currentItem()
        if it is None:
            return
        name = it.data(Qt.ItemDataRole.UserRole)

        def go() -> None:
            done = self.M.install(self.index, name, progress=self.say)
            self.say(("Installed " + ", ".join(done)) if done else f"{name} is already installed.")
        self._run(go)

    def remove(self) -> None:
        it = self.inst.currentItem()
        if it is not None:
            self._run(self.M.uninstall, it.data(Qt.ItemDataRole.UserRole))

    def update_all(self) -> None:
        def go() -> None:
            names = self.M.updates(self.index)
            for n in names:
                self.M.install(self.index, n, progress=self.say)
            self.say(f"Updated {len(names)} mod(s)." if names else "Every mod is up to date.")
        self._run(go)

    def apply_mods(self) -> None:
        if QMessageBox.question(self, "Apply mods", "Restart TotV now? The running world is saved first, "
                                "and Voices of the Void starts with the new mods.") != QMessageBox.StandardButton.Yes:
            return
        r = totvd({"op": "apply-mods"}, timeout=60)
        if not r.get("ok"):
            QMessageBox.warning(self, "Apply mods", r.get("error") or "failed")


def mods_main() -> int:
    os.umask(0o002)   # the profile is shared with r2modman and the game (group votv)
    app = QApplication(sys.argv)
    app.setApplicationName("votv-mods")
    app.setDesktopFileName("votv-mods")
    w = Mods()
    w.show()
    return app.exec()


# votv-logout / totv-updater ---------------------------------------------------------------
def logout_main() -> int:
    app = QApplication(sys.argv)  # needed for the dialogs
    app.setApplicationName("votv-logout")
    if "--yes" not in sys.argv and QMessageBox.question(
            None, "Log out", "Log out? The station goes back to the shared Home save.") != QMessageBox.StandardButton.Yes:
        return 0
    r = totvd({"op": "logout"})
    if not r.get("ok"):
        QMessageBox.warning(None, "Log out", r.get("error") or "failed")
        return 1
    return 0


class Updater(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("TotV Update")
        lay = QVBoxLayout(self)
        self.info = QLabel("Checking…")
        lay.addWidget(self.info)
        self.out = QPlainTextEdit()
        self.out.setReadOnly(True)
        lay.addWidget(self.out, 1)
        row = QHBoxLayout()
        self.check_b = QPushButton("Check")
        self.check_b.clicked.connect(self.check)
        self.go = QPushButton("Update now")
        self.go.clicked.connect(self.update_now)
        row.addWidget(self.check_b)
        row.addStretch(1)
        row.addWidget(self.go)
        lay.addLayout(row)
        self.resize(760, 480)
        self.poll = QTimer(self, interval=1000)
        self.poll.timeout.connect(self.show_log)
        QTimer.singleShot(100, self.check)

    def check(self) -> None:
        try:
            p = subprocess.run(["totv-update", "--check"], capture_output=True, text=True, timeout=180)
            self.out.setPlainText(p.stdout + p.stderr)
            self.info.setText("Updates are available." if p.returncode == 100 else
                              "TotV is up to date." if p.returncode == 0 else "The check failed (see below).")
        except (OSError, subprocess.TimeoutExpired) as e:
            self.info.setText(f"The check failed: {e}")

    def update_now(self) -> None:
        r = totvd({"op": "update"})
        if not r.get("ok"):
            QMessageBox.warning(self, "TotV Update", r.get("error") or "failed")
            return
        self.info.setText("Updating… the game keeps running; it restarts by itself if it was updated.")
        self.poll.start()

    def show_log(self) -> None:
        try:
            with open("/var/log/totv-update.log", errors="replace") as f:
                self.out.setPlainText(f.read()[-20000:])
            self.out.verticalScrollBar().setValue(self.out.verticalScrollBar().maximum())
        except OSError:
            pass
        r = totvd({"op": "update-status"}, timeout=5)
        if r.get("ok") and r.get("state") in ("inactive", "failed"):
            self.poll.stop()
            self.info.setText("Update finished." if r.get("state") == "inactive" else "The update failed (see the log).")


def updater_main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("totv-updater")
    app.setDesktopFileName("totv-updater")
    w = Updater()
    w.show()
    return app.exec()


def ctl_main(argv: list[str]) -> int:
    """votv-os-ctl restart-game | apply-mods | r2modman | logout | update | status"""
    ops = {"restart-game": "restart-game", "apply-mods": "apply-mods", "r2modman": "r2modman",
           "logout": "logout", "update": "update", "status": "status"}
    if len(argv) != 1 or argv[0] not in ops:
        print(ctl_main.__doc__, file=sys.stderr)
        return 2
    r = totvd({"op": ops[argv[0]]})
    print(json.dumps(r, indent=2))
    return 0 if r.get("ok") else 1

