"""The Linux end of the file IPC with the TotVOS game mod (see mod/TotVOS/Scripts/ipc.lua).

game-events.jsonl    game -> host, appended by the mod
host-commands.jsonl  host -> game, appended here; the mod polls it every 50 ms
*.json               snapshots replaced whole (screens.json, pc-frame.json by the host;
                     laptop-ui.json, inventory-ui.json by the mod)
"""
from __future__ import annotations

import fcntl
import itertools
import json
import os
import time
from pathlib import Path
from typing import Any, Iterator

from . import paths

_req = itertools.count(int(time.time() * 1000) % 1_000_000)


class GameLink:
    def __init__(self, runtime: Path | None = None, from_start: bool = False):
        self.dir = runtime or paths.runtime_dir()
        self.events = self.dir / "game-events.jsonl"
        self.commands = self.dir / "host-commands.jsonl"
        self._ino, size = self._stat(self.events)
        self._offset = 0 if from_start else size
        self._partial = b""

    @staticmethod
    def _stat(p: Path) -> tuple[int, int]:
        try:
            st = p.stat()
            return st.st_ino, st.st_size
        except OSError:
            return 0, 0

    # host -> game -------------------------------------------------------------
    def send(self, kind: str, **data: Any) -> int:
        req = next(_req)
        msg = {"type": kind, "req": req, **data}
        line = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        # Several host processes append; one write() per line under an flock keeps lines whole.
        with open(self.commands, "ab") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line)
            f.flush()
            fcntl.flock(f, fcntl.LOCK_UN)
        return req

    # game -> host -------------------------------------------------------------
    def poll(self) -> Iterator[dict]:
        ino, size = self._stat(self.events)
        if ino != self._ino or size < self._offset:   # a new session replaced or truncated it
            self._ino, self._offset, self._partial = ino, 0, b""
        if size == self._offset:
            return
        with open(self.events, "rb") as f:
            f.seek(self._offset)
            chunk = f.read(size - self._offset)
        self._offset += len(chunk)
        data = self._partial + chunk
        *lines, self._partial = data.split(b"\n")
        for raw in lines:
            if not raw.strip():
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if isinstance(msg, dict):
                yield msg

    # snapshots --------------------------------------------------------------------
    def read(self, name: str) -> Any:
        try:
            return json.loads((self.dir / name).read_text())
        except (OSError, ValueError):
            return None

    def write(self, name: str, data: Any) -> None:
        write_atomic(self.dir / name, json.dumps(data, separators=(",", ":")).encode())


def write_atomic(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def reset_session(runtime: Path | None = None) -> None:
    """Start of a game session: empty the logs so neither side replays stale lines."""
    d = runtime or paths.runtime_dir()
    for name in ("game-events.jsonl", "host-commands.jsonl", "laptop-ui.json", "inventory-ui.json"):
        try:
            (d / name).unlink()
        except FileNotFoundError:
            pass
    (d / "game-events.jsonl").touch()
    (d / "host-commands.jsonl").touch()
