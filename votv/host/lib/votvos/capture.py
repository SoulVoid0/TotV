"""Frames of the KDE "PC" session for the in-game laptop screen.

The PC desktop runs as a nested kwin_wayland (see bin/votv-pc-session) with its own
D-Bus session bus. KWin's ScreenShot2 interface renders the workspace into a pipe;
the nested KWin is started with KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 because the
bridge is a Python process KWin cannot match to a .desktop file. If D-Bus capture is
unavailable the bridge falls back to `spectacle -b -n -f`.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from pathlib import Path

from PyQt6.QtDBus import QDBusConnection, QDBusInterface, QDBusMessage, QDBusUnixFileDescriptor
from PyQt6.QtGui import QImage


class NestedCapture:
    SERVICE = "org.kde.KWin"
    PATH = "/org/kde/KWin/ScreenShot2"
    IFACE = "org.kde.KWin.ScreenShot2"

    def __init__(self, bus_address_file: Path):
        self.bus_address_file = bus_address_file
        self.conn: QDBusConnection | None = None
        self.address = ""
        self.dbus_ok = True

    def _connect(self) -> QDBusConnection | None:
        try:
            address = self.bus_address_file.read_text().strip()
        except OSError:
            return None
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
        try:
            env["DBUS_SESSION_BUS_ADDRESS"] = self.bus_address_file.read_text().strip()
        except OSError:
            return None
        env["WAYLAND_DISPLAY"] = "votv-pc"
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
