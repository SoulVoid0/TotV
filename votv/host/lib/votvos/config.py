"""Read and write the mod settings shared with the game (see mod/TotVOS/Scripts/config.lua)."""
from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from . import paths
from .ipc import write_atomic

DEFAULTS: dict[str, Any] = {
    "autoload": {"enabled": True, "mode": 0},
    "pc": {
        "replace_ingame_ui": True,
        "ingame_fps": 2,
        "ingame_width": 1024,
        "align_camera": True,
        "blend": 0.35,
        "overlay_delay": 0.4,
        "camera": {
            "distance_scale": 1.0, "offset_right": 0.0, "offset_up": 0.0, "offset_forward": 0.0,
            "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "fov": 0.0, "preview": False,
        },
    },
    "inventory": {"second_screen": "auto"},
    "relay": {"snapshot_hz": 4},
    "perf": {"enabled": True},
}


def merge(dst: dict, src: dict) -> dict:
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
    return dst


def _load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def effective() -> dict:
    v = copy.deepcopy(DEFAULTS)
    merge(v, _load(paths.SYSTEM_CONFIG))
    merge(v, _load(paths.user_config()))
    return v


def load_user() -> dict:
    return _load(paths.user_config())


def save_user(data: dict) -> None:
    p = paths.user_config()
    p.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(p, (json.dumps(data, indent=2, sort_keys=True) + "\n").encode())


def set_user(path: str, value: Any) -> dict:
    """set_user("pc.camera.pitch", 1.5): change one user setting, keep the rest."""
    data = load_user()
    node = data
    keys = path.split(".")
    for k in keys[:-1]:
        node = node.setdefault(k, {})
    node[keys[-1]] = value
    save_user(data)
    return data
