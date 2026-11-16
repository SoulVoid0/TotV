"""The saves of Voices of the Void on TotV OS, and which one runs.

Every save lives in one folder, /.VotV/saves/games (the game's SaveGames folder of the
votv system user, which runs the game). /.VotV/saves/registry.json says what each is:

  { "saves": { "<name>": { "title": "...", "mode": "home|story|infinite|custom|sandbox",
                           "owner": "<user>" or "*", "created": 1700000000,
                           "last_played": 0, "rules": {...}, "slot": "<slot file name>" } } }

<name> is the slot's base name; the game file is <prefix of the mode><name>.sav, the
prefix being the game's own (ui_saveSlots_C.getSavePrefix, learned by the mod into
prefixes.json). Built-in saves:
  default   the shared Home save (owner "*"): what runs at boot and while nobody is logged in
  <user>    each user's own save, titled after the username chosen in the installer
Saves made in the VotV Saves app are named <user>-<title>.

Which save runs is target.json in the runtime dir; the mod follows it (saves.lua).
"""
from __future__ import annotations

import fcntl
import json
import re
import shutil
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from . import paths
from .ipc import write_atomic

MODES = ["home", "story", "infinite", "custom", "sandbox"]
MODE_LABELS = {"home": "Home", "story": "Story", "infinite": "Infinite", "custom": "Custom",
               "sandbox": "Sandbox"}
GAME_MODE = {"story": 0, "infinite": 1, "custom": 3, "sandbox": 4}
DEFAULT = "default"
SHARED = "*"


class SaveError(Exception):
    pass


def slug(title: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_ -]", "", title).strip()
    s = re.sub(r"\s+", " ", s)
    return s[:40]


def _chmod_shared(p: Path) -> None:
    try:
        p.chmod(0o664)
    except OSError:
        pass


class Registry:
    def __init__(self, root: Path | None = None, runtime: Path | None = None):
        self.dir = root or paths.SAVES_DIR
        self.file = self.dir / "registry.json"
        self.games = self.dir / "games"
        self.runtime = runtime

    # storage ---------------------------------------------------------------------
    @contextmanager
    def _locked(self) -> Iterator[dict]:
        self.dir.mkdir(parents=True, exist_ok=True)
        lock = self.dir / ".registry.lock"
        with open(lock, "a+") as lf:
            _chmod_shared(lock)
            fcntl.flock(lf, fcntl.LOCK_EX)
            data = self._read()
            before = json.dumps(data, sort_keys=True)
            yield data
            if json.dumps(data, sort_keys=True) != before:
                write_atomic(self.file, (json.dumps(data, indent=2, sort_keys=True) + "\n").encode())
                _chmod_shared(self.file)
            fcntl.flock(lf, fcntl.LOCK_UN)

    def _read(self) -> dict:
        try:
            d = json.loads(self.file.read_text())
        except (OSError, ValueError):
            d = {}
        if not isinstance(d, dict):
            d = {}
        d.setdefault("saves", {})
        return d

    def all(self) -> dict[str, dict]:
        return self._read()["saves"]

    def get(self, name: str) -> dict | None:
        return self.all().get(name)

    # permissions ---------------------------------------------------------------------
    @staticmethod
    def visible_to(entry: dict, user: str) -> bool:
        return entry.get("owner") in (SHARED, user)

    def for_user(self, user: str) -> dict[str, dict]:
        return {n: e for n, e in self.all().items() if self.visible_to(e, user)}

    # the game's files -------------------------------------------------------------------
    def prefixes(self) -> dict[str, str]:
        try:
            d = json.loads((self.dir / "prefixes.json").read_text())
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def game_mode(self, entry: dict) -> int:
        mode = entry.get("mode", "home")
        if mode == "home":
            return int(entry.get("base_mode", 1))
        return GAME_MODE.get(mode, 1)

    def slot_file(self, name: str, entry: dict) -> Path | None:
        slot = entry.get("slot")
        if not slot:
            pre = self.prefixes().get(str(self.game_mode(entry)))
            if pre is None:
                return None
            slot = pre + name
        return self.games / f"{slot}.sav"

    # changes -----------------------------------------------------------------------------
    def ensure(self, name: str, title: str, mode: str, owner: str, rules: dict | None = None,
               base_mode: int = 1) -> dict:
        with self._locked() as d:
            e = d["saves"].get(name)
            if e is None:
                e = {"title": title, "mode": mode, "owner": owner, "created": int(time.time()),
                     "last_played": 0, "rules": rules or {}, "base_mode": base_mode}
                d["saves"][name] = e
            return dict(e)

    def ensure_builtin(self, user: str | None, user_mode: str = "home", base_mode: int = 1) -> None:
        self.ensure(DEFAULT, DEFAULT, "home", SHARED, base_mode=base_mode)
        if user:
            self.ensure(user, user, user_mode, user, base_mode=base_mode)

    def create(self, user: str, title: str, mode: str, rules: dict | None = None,
               base_mode: int = 1) -> str:
        if mode not in MODES:
            raise SaveError(f"unknown game mode {mode!r}")
        t = slug(title)
        if not t:
            raise SaveError("the save needs a name (letters, digits, spaces, - and _)")
        base = f"{user}-{t}"
        with self._locked() as d:
            name, n = base, 2
            while name in d["saves"] or name == DEFAULT:
                name, n = f"{base} {n}", n + 1
            d["saves"][name] = {"title": title.strip()[:60] or t, "mode": mode, "owner": user,
                                "created": int(time.time()), "last_played": 0,
                                "rules": rules or {}, "base_mode": base_mode}
        return name

    def _owned(self, d: dict, name: str, user: str, builtin_ok: bool = False) -> dict:
        e = d["saves"].get(name)
        if e is None:
            raise SaveError(f"no save {name!r}")
        if e.get("owner") != user:
            raise SaveError("this save belongs to someone else" if e.get("owner") != SHARED
                            else "the shared default save cannot be changed")
        if not builtin_ok and name == user:
            raise SaveError("your own save (named after you) cannot be renamed or deleted")
        return e

    def rename(self, user: str, name: str, title: str) -> None:
        with self._locked() as d:
            e = self._owned(d, name, user)
            if not slug(title):
                raise SaveError("the save needs a name")
            e["title"] = title.strip()[:60]

    def set_rules(self, user: str, name: str, rules: dict) -> None:
        with self._locked() as d:
            e = self._owned(d, name, user, builtin_ok=True)
            e["rules"] = rules

    def delete(self, user: str, name: str, running: str | None = None) -> None:
        if name == running:
            raise SaveError("this save is running; load another one first")
        with self._locked() as d:
            e = self._owned(d, name, user)
            f = self.slot_file(name, e)
            del d["saves"][name]
        if f and f.exists():
            trash = self.dir / "deleted"
            trash.mkdir(exist_ok=True)
            shutil.move(str(f), str(trash / f"{f.stem}.{int(time.time())}.sav"))

    def duplicate(self, user: str, name: str, title: str) -> str:
        src = self.get(name)
        if src is None or not self.visible_to(src, user):
            raise SaveError(f"no save {name!r}")
        new = self.create(user, title, src.get("mode", "home"), src.get("rules"), src.get("base_mode", 1))
        f = self.slot_file(name, src)
        if f and f.exists():
            nf = self.slot_file(new, self.get(new) or {})
            if nf:
                shutil.copy2(f, nf)
                _chmod_shared(nf)
        return new

    def played(self, name: str, slot: str | None) -> None:
        with self._locked() as d:
            e = d["saves"].get(name)
            if e is not None:
                e["last_played"] = int(time.time())
                if slot:
                    e["slot"] = slot

    # which save runs --------------------------------------------------------------------
    def target_file(self) -> Path:
        return (self.runtime or paths.runtime_dir()) / "target.json"

    def running(self) -> dict | None:
        try:
            t = json.loads(self.target_file().read_text())
            return t if isinstance(t, dict) else None
        except (OSError, ValueError):
            return None

    def load(self, name: str, user: str | None, by: str = "") -> dict:
        e = self.get(name)
        if e is None:
            raise SaveError(f"no save {name!r}")
        if user is not None and not self.visible_to(e, user):
            raise SaveError("this save belongs to someone else")
        t: dict[str, Any] = {"seq": time.time_ns() // 1000, "name": name, "title": e.get("title", name),
                             "mode": e.get("mode", "home"), "base_mode": int(e.get("base_mode", 1)),
                             "create": True, "rules": e.get("rules") or {},
                             "by": by or (user or "")}
        f = self.target_file()
        write_atomic(f, json.dumps(t).encode())
        _chmod_shared(f)
        return t


def current_session_user(runtime: Path | None = None) -> str | None:
    try:
        d = json.loads(((runtime or paths.runtime_dir()) / "session.json").read_text())
    except (OSError, ValueError):
        return None
    u = d.get("user") if isinstance(d, dict) else None
    return u if isinstance(u, str) and re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", u) else None

