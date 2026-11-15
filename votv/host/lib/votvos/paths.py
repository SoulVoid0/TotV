"""Where the TotV OS / VotV integration keeps its files on the Linux side."""
from __future__ import annotations

import os
from pathlib import Path

SYSTEM_CONFIG = Path("/etc/totv/votv.json")
USER_CONF = Path("/etc/totv/user.conf")
GAME_DIR = Path(os.environ.get("VOTV_GAME_DIR", "/opt/votv"))
LIB_DIR = Path(os.environ.get("VOTV_OS_LIB", "/usr/lib/votv-os"))


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    d = Path(os.environ.get("VOTV_OS_RUNTIME_LINUX", Path(base) / "votv-os"))
    d.mkdir(parents=True, exist_ok=True)
    (d / "frames").mkdir(exist_ok=True)
    return d


def user_config() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "totv" / "votv.json"


def to_windows(path: os.PathLike | str) -> str:
    """Linux path -> the path the game sees under LSIW, where C:\\ is /."""
    p = str(Path(path).resolve() if Path(path).exists() else Path(path))
    return "C:" + p.replace("/", "\\")


def read_user_conf(path: Path = USER_CONF) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k.strip()] = v
    return out
