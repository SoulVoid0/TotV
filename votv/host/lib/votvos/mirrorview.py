"""Draws a mirrored game screen (laptop-ui.json / inventory-ui.json written by the mod)
and turns clicks, typing, wheel and drags into commands for the game.

The snapshot is a flat list of widgets with rectangles in the game screen's own
units; the view scales it to fit, keeping the aspect ratio.
"""
from __future__ import annotations

from PyQt6.QtCore import QPointF, QRectF, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QPainter, QPen
from PyQt6.QtWidgets import QLineEdit, QWidget

from .ipc import GameLink

BG = QColor("#0d1014")
FG = QColor("#d8dee6")
ACCENT = QColor("#3daee9")
BUTTON = QColor("#232a33")
BUTTON_HOVER = QColor("#2f3946")
DISABLED = QColor("#6b7480")


class MirrorView(QWidget):
    """prefix: 'relay' for the laptop (relay_click, ...) or 'inv' for the inventory."""

    statusChanged = pyqtSignal(str)

    def __init__(self, link: GameLink, snapshot_file: str, prefix: str,
                 allow_tap: bool = False, parent: QWidget | None = None):
        super().__init__(parent)
        self.link = link
        self.file = snapshot_file
        self.prefix = prefix
        self.allow_tap = allow_tap
        self.snap: dict = {}
        self.seq = -1
        self.hover: str | None = None
        self.drag_slider: dict | None = None
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMinimumSize(320, 200)
        self.editor = QLineEdit(self)
        self.editor.hide()
        self.editor.returnPressed.connect(lambda: self._commit_edit(True))
        self.editor.editingFinished.connect(lambda: self._commit_edit(False))
        self.edit_id: str | None = None
        self.timer = QTimer(self, interval=100)
        self.timer.timeout.connect(self.refresh)
        self.timer.start()

    # data ------------------------------------------------------------------------------
    def refresh(self) -> None:
        snap = self.link.read(self.file)
        if isinstance(snap, dict) and snap.get("seq") != self.seq:
            self.snap, self.seq = snap, snap.get("seq")
            self.update()

    def items(self) -> list[dict]:
        return self.snap.get("items", []) if self.snap else []

    # geometry -----------------------------------------------------------------------------
    def _transform(self) -> tuple[float, float, float]:
        w = float(self.snap.get("width") or 0)
        h = float(self.snap.get("height") or 0)
        if w <= 0 or h <= 0:
            # Fall back to the extent of the items.
            for it in self.items():
                w = max(w, it["x"] + it["w"])
                h = max(h, it["y"] + it["h"])
        if w <= 0 or h <= 0:
            return 1.0, 0.0, 0.0
        s = min(self.width() / w, self.height() / h)
        return s, (self.width() - w * s) / 2, (self.height() - h * s) / 2

    def _rect(self, it: dict) -> QRectF:
        s, ox, oy = self._transform()
        return QRectF(ox + it["x"] * s, oy + it["y"] * s, it["w"] * s, it["h"] * s)

    def _hit(self, pos: QPointF, kinds: tuple[str, ...]) -> dict | None:
        best = None
        for it in self.items():                    # later items draw on top
            if it.get("kind") in kinds and self._rect(it).contains(pos):
                best = it
        return best

    # painting -------------------------------------------------------------------------------
    def paintEvent(self, _event) -> None:   # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.fillRect(self.rect(), BG)
        if not self.items():
            p.setPen(DISABLED)
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "Waiting for the game…")
            return
        s, _, _ = self._transform()
        font = QFont(self.font())
        for it in self.items():
            r = self._rect(it)
            kind = it.get("kind")
            enabled = it.get("enabled", True)
            if kind == "image":
                c = it.get("color")
                if c and len(c) == 4 and c[3] > 0.05:
                    p.fillRect(r, QColor.fromRgbF(*(max(0.0, min(1.0, float(v))) for v in c[:3]), min(1.0, float(c[3])) * 0.35))
            elif kind == "button":
                p.setPen(QPen(ACCENT if it["id"] == self.hover else QColor("#3b4552"), 1))
                p.setBrush(BUTTON_HOVER if it["id"] == self.hover else BUTTON)
                p.drawRoundedRect(r.adjusted(0.5, 0.5, -0.5, -0.5), 3, 3)
            elif kind == "edit":
                p.setPen(QPen(ACCENT, 1))
                p.setBrush(QColor("#11161c"))
                p.drawRect(r)
                self._text(p, r.adjusted(4, 0, -4, 0), it.get("text") or "", font, s, FG, left=True)
            elif kind == "checkbox":
                box = QRectF(r.x(), r.y() + (r.height() - min(r.height(), 16)) / 2, min(r.height(), 16), min(r.height(), 16))
                p.setPen(QPen(ACCENT, 1))
                p.setBrush(ACCENT if it.get("checked") else QColor("#11161c"))
                p.drawRect(box)
            elif kind in ("slider", "progress"):
                v = float(it.get("value") or 0)
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(QColor("#2a323c"))
                p.drawRect(r)
                p.setBrush(ACCENT)
                p.drawRect(QRectF(r.x(), r.y(), r.width() * max(0.0, min(1.0, v)), r.height()))
            elif kind in ("text", "combo"):
                self._text(p, r, it.get("text") or "", font, s, FG if enabled else DISABLED)

    @staticmethod
    def _text(p: QPainter, r: QRectF, text: str, font: QFont, scale: float, color: QColor, left: bool = False) -> None:
        if not text:
            return
        f = QFont(font)
        f.setPixelSize(max(8, min(int(r.height() * 0.75), int(18 * max(scale, 0.6)))))
        p.setFont(f)
        p.setPen(color)
        flags = Qt.AlignmentFlag.AlignVCenter | (Qt.AlignmentFlag.AlignLeft if left else Qt.AlignmentFlag.AlignHCenter)
        p.drawText(r, int(flags) | int(Qt.TextFlag.TextWordWrap), text)

    # input ------------------------------------------------------------------------------------
    def send(self, action: str, **data) -> None:
        self.link.send(f"{self.prefix}_{action}", **data)

    def mouseMoveEvent(self, e) -> None:   # noqa: N802
        if self.drag_slider is not None:
            self._slider_to(self.drag_slider, e.position())
            return
        it = self._hit(e.position(), ("button", "checkbox", "edit", "slider", "combo"))
        hid = it["id"] if it else None
        if hid != self.hover:
            self.hover = hid
            self.setCursor(Qt.CursorShape.PointingHandCursor if it else Qt.CursorShape.ArrowCursor)
            self.update()

    def mousePressEvent(self, e) -> None:   # noqa: N802
        if e.button() != Qt.MouseButton.LeftButton:
            return
        pos = e.position()
        it = self._hit(pos, ("button", "checkbox", "edit", "slider"))
        if it is None:
            if self.allow_tap:
                s, ox, oy = self._transform()
                w, h = float(self.snap.get("width") or 1), float(self.snap.get("height") or 1)
                self.send("tap", u=(pos.x() - ox) / s / w, v=(pos.y() - oy) / s / h)
            return
        kind = it["kind"]
        if kind in ("button", "checkbox"):
            self.send("click", id=it["id"])
            self.statusChanged.emit(f"pressed {it.get('name', '')}")
        elif kind == "edit":
            self._open_editor(it)
        elif kind == "slider":
            self.drag_slider = it
            self._slider_to(it, pos)

    def mouseReleaseEvent(self, _e) -> None:   # noqa: N802
        self.drag_slider = None

    def _slider_to(self, it: dict, pos: QPointF) -> None:
        r = self._rect(it)
        v = max(0.0, min(1.0, (pos.x() - r.x()) / max(r.width(), 1)))
        it["value"] = v
        self.send("value", id=it["id"], value=v)
        self.update()

    def wheelEvent(self, e) -> None:   # noqa: N802
        it = self._hit(e.position(), ("scroll",))
        if it is not None:
            off = float(it.get("offset") or 0) - e.angleDelta().y() / 2
            it["offset"] = max(0.0, off)
            self.send("value", id=it["id"], value=it["offset"])

    def _open_editor(self, it: dict) -> None:
        self.edit_id = it["id"]
        self.editor.setGeometry(self._rect(it).toRect())
        self.editor.setText(it.get("text") or "")
        self.editor.show()
        self.editor.setFocus()
        self.editor.selectAll()

    def _commit_edit(self, commit: bool) -> None:
        if self.edit_id is None:
            return
        self.send("text", id=self.edit_id, text=self.editor.text(), commit=commit)
        self.edit_id = None
        self.editor.hide()
        self.setFocus()

