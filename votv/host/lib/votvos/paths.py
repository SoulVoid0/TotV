"""Where the TotV OS / VotV integration keeps its files on the Linux side.

/.VotV/<version>/           the game (Voices of the Void), /.VotV/current -> the one that runs
/.VotV/saves/games/         the game's SaveGames folder (every save, all users)
/.VotV/saves/registry.json  which save is whose, its title and game mode (VotV Saves app)
/.VotV/config/<user>.json   each user's calibration (VotV Screen Setup)
/.VotV/r2modman/            r2modman (app/) and its data: profiles and mods
/run/totv/votv-os/          the IPC with the game mod (game-events.jsonl, target.json, ...)
/run/totv/shell/            the shell compositor's Wayland socket (wayland-0) and audio
/run/totv/pc/<user>/        a logged-in user's PC desktop Wayland socket (wayland-0)
"""
from __future__ import annotations

import os
import pwd
from pathlib import Path

SYSTEM_CONFIG = Path(os.environ.get("VOTV_OS_SYSCFG_LINUX", "/etc/totv/votv.json"))
TOTV_CONF = Path("/etc/totv/totv.conf")
USER_CONF = Path("/etc/totv/user.conf")
VOTV_ROOT = Path(os.environ.get("VOTV_ROOT", "/.VotV"))
GAME_DIR = Path(os.environ.get("VOTV_GAME_DIR", str(VOTV_ROOT / "current")))
SAVES_DIR = VOTV_ROOT / "saves"
SAVEGAMES = SAVES_DIR / "games"
REGISTRY = SAVES_DIR / "registry.json"
PREFIXES = SAVES_DIR / "prefixes.json"
USER_CFG_DIR = VOTV_ROOT / "config"
R2_ROOT = VOTV_ROOT / "r2modman"
LIB_DIR = Path(os.environ.get("VOTV_OS_LIB", "/usr/lib/votv-os"))
SHELL_DIR = Path(os.environ.get("TOTV_SHELL_DIR", "/run/totv/shell"))
PC_DIR = Path("/run/totv/pc")
LOGIN_SOCKET = Path(os.environ.get("TOTV_LOGIN_SOCKET", "/run/totv/totvd.sock"))
SYSTEM_USER = "votv"


def runtime_dir() -> Path:
    d = Path(os.environ.get("VOTV_OS_RUNTIME_LINUX", "/run/totv/votv-os"))
    d.mkdir(parents=True, exist_ok=True)
    try:
        (d / "frames").mkdir(exist_ok=True)
    except OSError:
        pass
    return d


def me() -> str:
    return pwd.getpwuid(os.getuid()).pw_name


def user_config(user: str | None = None) -> Path:
    """A user's calibration file; the game (as the votv system user) reads the logged-in user's."""
    return USER_CFG_DIR / f"{user or me()}.json"


def to_windows(path: os.PathLike | str) -> str:
    """Linux path -> the path the game sees under LSIW, where C:\\ is /."""
    p = str(Path(path).resolve() if Path(path).exists() else Path(path))
    return "C:" + p.replace("/", "\\")


def read_kv(path: Path) -> dict[str, str]:
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


read_user_conf = read_kv
