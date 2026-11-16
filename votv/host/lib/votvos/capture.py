"""Frames of the KDE "PC" session for the in-game laptop screen.

The PC desktop runs as a nested kwin_wayland (see bin/votv-pc-session) with its own
D-Bus session bus. votv-pc-agent, inside that session, uses KWin's ScreenShot2
interface, which renders the workspace into a pipe; the nested KWin is started with
KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 because the agent is a Python process KWin
cannot match to a .desktop file. If D-Bus capture is unavailable it falls back to
`spectacle -b -n -f`. FrameWriter publishes frames for the mod (pc-frame.json + BMP).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from PyQt6.QtDBus import QDBusConnection, QDBusInterface, QDBusMessage, QDBusUnixFileDescriptor
from PyQt6.QtGui import QImage


class NestedCapture:
    SERVICE = "org.kde.KWin"
    PATH = "/org/kde/KWin/ScreenShot2"
    IFACE = "org.kde.KWin.ScreenShot2"

    def __init__(self, bus_address_file: Path | None = None, address: str = ""):
        self.bus_address_file = bus_address_file
        self.fixed_address = address
        self.conn: QDBusConnection | None = None
        self.address = ""
        self.dbus_ok = True

    def _bus_address(self) -> str:
        if self.fixed_address:
            return self.fixed_address
        try:
            return self.bus_address_file.read_text().strip() if self.bus_address_file else ""
        except OSError:
            return ""

    def _connect(self) -> QDBusConnection | None:
        address = self._bus_address()
        if not address:
            return None
        if self.conn is not None and address == self.address and self.conn.isConnected():
            return self.conn
        self.address = address
        self.conn = QDBusConnection.connectToBus(address, f"votv-pc-{abs(hash(address))}")
        return self.conn if self.conn.isConnected() else None

    def grab(self) -> QImage | None:
        if self.dbus_ok:
            img = self._grab_dbus()
            if img is not None:
                return img
        return self._grab_spectacle()

    def _grab_dbus(self) -> QImage | None:
        conn = self._connect()
        if conn is None:
            return None
        r, w = os.pipe()
        try:
            iface = QDBusInterface(self.SERVICE, self.PATH, self.IFACE, conn)
            if not iface.isValid():
                return None
            reply = iface.call("CaptureWorkspace", {"include-cursor": True, "native-resolution": False},
                               QDBusUnixFileDescriptor(w))
            os.close(w)
            w = -1
            if reply.type() == QDBusMessage.MessageType.ErrorMessage:
                if "NoAuthorized" in reply.errorName() or "UnknownMethod" in reply.errorName():
                    self.dbus_ok = False
                return None
            args = reply.arguments()
            meta = args[0] if args else {}
            width, height = int(meta.get("width", 0)), int(meta.get("height", 0))
            stride, fmt = int(meta.get("stride", 0)), int(meta.get("format", 0))
            if not (width and height and stride):
                return None
            data = bytearray()
            while True:
                chunk = os.read(r, 1 << 20)
                if not chunk:
                    break
                data += chunk
            if len(data) < stride * height:
                return None
            img = QImage(bytes(data), width, height, stride, QImage.Format(fmt))
            return img.copy()   # detach from the Python buffer
        finally:
            os.close(r)
            if w >= 0:
                os.close(w)

    def _grab_spectacle(self) -> QImage | None:
        env = dict(os.environ)
        address = self._bus_address()
        if not address:
            return None
        env["DBUS_SESSION_BUS_ADDRESS"] = address
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            out = tmp.name
        try:
            subprocess.run(["spectacle", "-b", "-n", "-f", "-o", out], env=env, timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            img = QImage(out)
            return None if img.isNull() else img
        except (OSError, subprocess.TimeoutExpired):
            return None
        finally:
            try:
                os.unlink(out)
            except OSError:
                pass


def frame_digest(img: QImage) -> bytes:
    """A cheap change detector: a 192x120 thumbnail's bytes."""
    thumb = img.scaled(192, 120).convertToFormat(QImage.Format.Format_RGB888)
    ptr = thumb.constBits()
    ptr.setsize(thumb.sizeInBytes())
    return hashlib.blake2b(bytes(ptr), digest_size=16).digest()


class FrameWriter:
    """Writes frames of the PC for the in-game screen: frames/pc-<seq>.bmp + pc-frame.json.

    Only when the picture changed, at most `fps` per second, never while the real
    desktop covers the game (bridge-state.json says so)."""

    def __init__(self, runtime: Path, source: str):
        self.rt = runtime
        self.source = source
        self.last_digest = b""
        self.last_at = 0.0
        self.seq = int(time.time()) % 100000 * 10

    def due(self, fps: float) -> bool:
        if fps <= 0:
            return False
        try:
            state = json.loads((self.rt / "bridge-state.json").read_text())
            if state.get("pc_visible"):
                return False
        except (OSError, ValueError):
            pass
        return time.monotonic() - self.last_at >= 1.0 / fps

    def write(self, img: QImage, width: int = 1024) -> bool:
        self.last_at = time.monotonic()
        if img is None or img.isNull():
            return False
        if img.width() > width:
            img = img.scaledToWidth(width)
        digest = frame_digest(img)
        if digest == self.last_digest:
            return False
        self.last_digest = digest
        self.seq += 1
        name = f"pc-{self.seq}.bmp"
        frames = self.rt / "frames"
        frames.mkdir(exist_ok=True)
        img = img.convertToFormat(QImage.Format.Format_RGB32)
        tmp = frames / f".{name}.tmp"
        if not img.save(str(tmp), "BMP"):
            return False
        os.chmod(tmp, 0o664)
        os.replace(tmp, frames / name)
        meta = json.dumps({"seq": self.seq, "file": f"frames/{name}", "w": img.width(), "h": img.height(),
                           "source": self.source}).encode()
        tmpj = self.rt / f".pc-frame.{os.getpid()}.tmp"
        tmpj.write_bytes(meta)
        os.chmod(tmpj, 0o664)
        os.replace(tmpj, self.rt / "pc-frame.json")
        for old in frames.glob("pc-*.bmp"):
            try:
                if int(old.stem.split("-")[1]) < self.seq - 4:
                    old.unlink()
            except (ValueError, OSError):
                pass
        return True
