"""The three Qt apps of the integration.

votv-pc            (KDE desktop) the game's own PC, relayed: email, store, upgrades,
                   cameras, drives, signals... whatever its UI shows, driven remotely.
votv-inventory     (second monitor, host session) the game's inventory screen.
votv-screen-setup  (KDE desktop) line the in-game screen up with the real monitor.
"""
from __future__ import annotations

import os
import sys

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout,
                             QHBoxLayout, QLabel, QMainWindow, QPushButton, QSpinBox,
                             QStatusBar, QToolBar, QVBoxLayout, QWidget)

from . import config, paths
from .ipc import GameLink
from .mirrorview import MirrorView


def _link() -> GameLink:
    return GameLink(paths.runtime_dir())


# votv-pc ------------------------------------------------------------------------------
class PcRelay(QMainWindow):
    def __init__(self):
        super().__init__()
        self.link = _link()
        self.setWindowTitle("VotV PC")
        self.view = MirrorView(self.link, "laptop-ui.json", "relay", allow_tap=True)
        self.setCentralWidget(self.view)
        bar = QToolBar("PC")
        bar.setMovable(False)
        self.addToolBar(bar)
        self.points = QLabel("")
        bar.addWidget(QLabel(" Station PC "))
        bar.addSeparator()
        bar.addWidget(self.points)
        self.setStatusBar(QStatusBar())
        self.view.statusChanged.connect(lambda s: self.statusBar().showMessage(s, 2000))
        self.resize(1100, 700)
        # Stay subscribed while open; the mod stops snapshotting when we unsubscribe.
        self.sub = QTimer(self, interval=5000)
        self.sub.timeout.connect(lambda: self.link.send("relay_subscribe", on=True))
        self.sub.start()
        self.link.send("relay_subscribe", on=True)
        self.tick = QTimer(self, interval=500)
        self.tick.timeout.connect(self._status)
        self.tick.start()

    def _status(self) -> None:
        pts = (self.view.snap or {}).get("points")
        self.points.setText(f"Points: {pts}" if pts is not None else "")

    def keyPressEvent(self, e) -> None:   # noqa: N802
        if e.text() and not self.view.editor.isVisible():
            self.link.send("relay_chars", text=e.text())
        super().keyPressEvent(e)

    def closeEvent(self, e) -> None:   # noqa: N802
        self.link.send("relay_subscribe", on=False)
        super().closeEvent(e)


# votv-inventory ------------------------------------------------------------------------
class Inventory(QWidget):
    def __init__(self):
        super().__init__()
        self.link = _link()
        self.setWindowTitle("VotV Inventory")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        top = QHBoxLayout()
        title = QLabel("Inventory")
        title.setStyleSheet("font-size: 20px; padding: 8px; color: #d8dee6")
        close = QPushButton("Close  (Tab)")
        close.clicked.connect(lambda: self.link.send("inv_close"))
        top.addWidget(title)
        top.addStretch(1)
        top.addWidget(close)
        lay.addLayout(top)
        self.view = MirrorView(self.link, "inventory-ui.json", "inv")
        lay.addWidget(self.view, 1)
        self.setStyleSheet("background: #0d1014;")
        (paths.runtime_dir() / "inventory.pid").write_text(str(os.getpid()))

    def keyPressEvent(self, e) -> None:   # noqa: N802
        if e.key() in (Qt.Key.Key_Tab, Qt.Key.Key_Escape, Qt.Key.Key_I):
            self.link.send("inv_close")
        super().keyPressEvent(e)


# votv-screen-setup --------------------------------------------------------------------
CAMERA_FIELDS = [
    ("distance_scale", "Distance", 0.3, 3.0, 0.01),
    ("offset_right", "Move right (cm)", -50.0, 50.0, 0.1),
    ("offset_up", "Move up (cm)", -50.0, 50.0, 0.1),
    ("offset_forward", "Move closer (cm)", -50.0, 50.0, 0.1),
    ("pitch", "Tilt up/down (°)", -30.0, 30.0, 0.1),
    ("yaw", "Turn left/right (°)", -30.0, 30.0, 0.1),
    ("roll", "Roll (°)", -15.0, 15.0, 0.1),
    ("fov", "Field of view (° / 0 = game)", 0.0, 140.0, 0.5),
]


class ScreenSetup(QWidget):
    """While open, the game shows the calibration view live (pc.camera.preview)."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("VotV Screen Setup")
        self.link = _link()
        eff = config.effective()
        cam = eff["pc"]["camera"]
        form = QFormLayout(self)
        form.addRow(QLabel("Line the in-game PC screen up with this monitor.\n"
                           "The game shows the view live while this window is open."))
        self.spins: dict[str, QDoubleSpinBox] = {}
        for key, label, lo, hi, step in CAMERA_FIELDS:
            sp = QDoubleSpinBox()
            sp.setRange(lo, hi)
            sp.setSingleStep(step)
            sp.setDecimals(2)
            sp.setValue(float(cam.get(key, 0.0)))
            sp.valueChanged.connect(lambda v, k=key: config.set_user(f"pc.camera.{k}", float(v)))
            self.spins[key] = sp
            form.addRow(label, sp)
        self.align = QCheckBox("Move the camera to the screen when I use the PC")
        self.align.setChecked(bool(eff["pc"].get("align_camera", True)))
        self.align.toggled.connect(lambda v: config.set_user("pc.align_camera", bool(v)))
        form.addRow(self.align)
        self.replace = QCheckBox("Show this desktop on the in-game PC")
        self.replace.setChecked(bool(eff["pc"].get("replace_ingame_ui", True)))
        self.replace.toggled.connect(lambda v: config.set_user("pc.replace_ingame_ui", bool(v)))
        form.addRow(self.replace)
        self.fps = QSpinBox()
        self.fps.setRange(0, 10)
        self.fps.setValue(int(eff["pc"].get("ingame_fps", 2)))
        self.fps.valueChanged.connect(lambda v: config.set_user("pc.ingame_fps", int(v)))
        form.addRow("In-game screen refreshes / s", self.fps)
        self.inv = QComboBox()
        self.inv.addItems(["auto", "on", "off"])
        self.inv.setCurrentText(str(eff["inventory"].get("second_screen", "auto")))
        self.inv.currentTextChanged.connect(lambda v: config.set_user("inventory.second_screen", v))
        form.addRow("Inventory on second monitor", self.inv)
        reset = QPushButton("Reset camera")
        reset.clicked.connect(self._reset)
        form.addRow(reset)
        config.set_user("pc.camera.preview", True)

    def _reset(self) -> None:
        for key, sp in self.spins.items():
            sp.setValue(float(config.DEFAULTS["pc"]["camera"][key]))

    def closeEvent(self, e) -> None:   # noqa: N802
        config.set_user("pc.camera.preview", False)
        super().closeEvent(e)


def _run(cls, name: str) -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(name)
    app.setDesktopFileName(name)
    w = cls()
    if name == "votv-inventory":
        w.showFullScreen()
    else:
        w.show()
    return app.exec()


def pc_main() -> int:
    return _run(PcRelay, "votv-pc")


def inventory_main() -> int:
    return _run(Inventory, "votv-inventory")


def setup_main() -> int:
    return _run(ScreenSetup, "votv-screen-setup")
