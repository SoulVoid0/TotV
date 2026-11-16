"""Voices of the Void mods on TotV OS, without r2modman's "game must be closed" rule.

The game always runs on TotV OS, and r2modman does not install mods while it does. The
VotV Mods app (votv-mods) uses this module instead: it downloads packages from
Thunderstore (with their dependencies) and installs them into the r2modman profile the
game loads, exactly where r2modman would (so r2modman lists them too):

  <profile>/shimloader/mod/<Owner-Name>/...      UE4SS mods (the default)
  <profile>/shimloader/pak/<Owner-Name>/...      .pak files and a package's pak/ folder
  <profile>/shimloader/overlay/<Owner-Name>/...  a package's overlay/ folder
  <profile>/shimloader/cfg/...                    a package's cfg/ folder (not tracked)
  <profile>/mods.yml                              r2modman's list of installed packages

Nothing changes in the running game: "Apply mods" restarts TotV OS (pending.json says
what changed since the last start). Thunderstore-unreal_shimloader is part of the OS and
TotV-TotVOS is the OS's own mod; neither is installed or removed here.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import time
import urllib.request
import zipfile
from pathlib import Path

from . import config, paths

COMMUNITY = "voices-of-the-void"
INDEX_URL = f"https://thunderstore.io/c/{COMMUNITY}/api/v1/package/"
DOWNLOAD_URL = "https://thunderstore.io/package/download/{owner}/{name}/{version}/"
BUILTIN = {"Thunderstore-unreal_shimloader", "TotV-TotVOS"}
ROUTES = {"mod": "shimloader/mod", "pak": "shimloader/pak", "overlay": "shimloader/overlay",
          "cfg": "shimloader/cfg"}
UA = {"User-Agent": "TotV-OS votv-mods"}
FULL_RE = re.compile(r"^([A-Za-z0-9_]+)-([A-Za-z0-9_]+)(?:-(\d+\.\d+\.\d+))?$")


class ModError(Exception):
    pass


def profile_dir(name: str | None = None) -> Path:
    name = name or config.effective().get("mods", {}).get("profile", "Default")
    return paths.R2_ROOT / "r2modmanPlus-local" / "VotV" / "profiles" / name


def cache_dir() -> Path:
    return paths.R2_ROOT / "r2modmanPlus-local" / "VotV" / "cache"


# The Thunderstore index -----------------------------------------------------------------
def fetch_index(max_age: float = 3600) -> list[dict]:
    f = cache_dir() / "totv-package-index.json"
    try:
        if time.time() - f.stat().st_mtime < max_age:
            return json.loads(f.read_text())
    except (OSError, ValueError):
        pass
    req = urllib.request.Request(INDEX_URL, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.loads(r.read())
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(data))
    except OSError:
        pass
    return data


def by_full_name(index: list[dict]) -> dict[str, dict]:
    return {p["full_name"]: p for p in index}


def search(index: list[dict], text: str = "", nsfw: bool = False) -> list[dict]:
    t = text.lower().strip()
    out = []
    for p in index:
        if p.get("is_deprecated"):
            continue
        if not nsfw and ("NSFW" in (p.get("categories") or []) or p.get("has_nsfw_content")):
            continue
        v = (p.get("versions") or [{}])[0]
        hay = f"{p['full_name']} {v.get('description', '')}".lower()
        if not t or t in hay:
            out.append(p)
    out.sort(key=lambda p: -sum(v.get("downloads", 0) for v in p.get("versions", [])))
    return out


# mods.yml (r2modman's format: a YAML list of ManifestV2 objects) --------------------------
def _yaml_scalar(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        return "[" + ", ".join(json.dumps(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k}: {_yaml_scalar(x)}" for k, x in v.items()) + "}"
    return json.dumps(str(v))


def write_mods_yml(profile: Path, mods: list[dict]) -> None:
    lines = []
    for m in mods:
        first = True
        for k, v in m.items():
            lines.append(("- " if first else "  ") + f"{k}: {_yaml_scalar(v)}")
            first = False
    tmp = profile / ".mods.yml.tmp"
    tmp.write_text("\n".join(lines) + "\n")
    os.replace(tmp, profile / "mods.yml")


def read_mods_yml(profile: Path) -> list[dict]:
    """Reads what write_mods_yml (and r2modman, for these keys) writes."""
    try:
        import yaml   # python-yaml, when present
        d = yaml.safe_load((profile / "mods.yml").read_text())
        return d if isinstance(d, list) else []
    except ImportError:
        pass
    except (OSError, ValueError):
        return []
    out: list[dict] = []
    try:
        text = (profile / "mods.yml").read_text()
    except OSError:
        return out
    cur: dict | None = None
    for line in text.splitlines():
        m = re.match(r"^(- |  )([A-Za-z]+):\s*(.*)$", line)
        if not m:
            continue
        if m[1] == "- ":
            cur = {}
            out.append(cur)
        if cur is None:
            continue
        raw = m[3].strip()
        if raw.startswith("{") and raw.endswith("}"):
            val = {kv.split(":")[0].strip(): int(kv.split(":")[1]) for kv in raw[1:-1].split(",") if ":" in kv}
        elif raw.startswith("["):
            try:
                val = json.loads(raw)
            except ValueError:
                val = [x.strip() for x in raw[1:-1].split(",") if x.strip()]
        elif raw in ("true", "false"):
            val = raw == "true"
        else:
            try:
                val = json.loads(raw)
            except ValueError:
                val = raw.strip("'\"")
        cur[m[2]] = val
    return out


def installed(profile: Path | None = None) -> dict[str, dict]:
    p = profile or profile_dir()
    return {m.get("name", ""): m for m in read_mods_yml(p)}


def _version(m: dict) -> str:
    v = m.get("versionNumber") or {}
    return f"{v.get('major', 0)}.{v.get('minor', 0)}.{v.get('patch', 0)}"


# Install / remove ------------------------------------------------------------------------
def _route_for(rel: str) -> tuple[str, str]:
    """(route key, path inside the route) for a file at `rel` in a package zip."""
    parts = rel.split("/")
    top = parts[0].lower()
    if len(parts) > 1 and top in ROUTES:
        return top, "/".join(parts[1:])
    if rel.lower().endswith((".pak", ".utoc", ".ucas")) and len(parts) == 1:
        return "pak", rel
    return "mod", rel


def install_zip(profile: Path, full: str, data: bytes) -> list[str]:
    files = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            rel = info.filename.replace("\\", "/").lstrip("/")
            if info.is_dir() or not rel or ".." in rel.split("/"):
                continue
            if rel in ("manifest.json", "icon.png", "README.md", "CHANGELOG.md", "LICENSE"):
                continue
            route, inner = _route_for(rel)
            base = profile / ROUTES[route]
            dest = base / inner if route == "cfg" else base / full / inner
            dest.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            files.append(str(dest.relative_to(profile)))
    return files


def _entry(pkg: dict, ver: dict) -> dict:
    major, minor, patch = (int(x) for x in ver["version_number"].split("."))
    return {"manifestVersion": 1, "name": pkg["full_name"], "authorName": pkg["owner"],
            "websiteUrl": ver.get("website_url", ""), "displayName": pkg["name"],
            "description": ver.get("description", ""), "gameVersion": "0", "networkMode": "both",
            "packageType": "other", "installMode": "managed",
            "installedAtTime": int(time.time() * 1000), "loaders": [],
            "dependencies": ver.get("dependencies", []), "incompatibilities": [],
            "optionalDependencies": [], "versionNumber": {"major": major, "minor": minor, "patch": patch},
            "enabled": True, "icon": ""}


def plan(index: list[dict], full_name: str, profile: Path | None = None) -> list[tuple[dict, dict]]:
    """The packages (with their dependencies, latest versions) to install for full_name."""
    pk = by_full_name(index)
    have = installed(profile)
    out: list[tuple[dict, dict]] = []
    seen: set[str] = set()

    def walk(name: str) -> None:
        if name in seen or name in BUILTIN:
            return
        seen.add(name)
        p = pk.get(name)
        if p is None:
            raise ModError(f"{name} is not on Thunderstore")
        ver = p["versions"][0]
        for dep in ver.get("dependencies", []):
            m = FULL_RE.match(dep)
            if m:
                walk(f"{m[1]}-{m[2]}")
        if name in have and _version(have[name]) == ver["version_number"]:
            return
        out.append((p, ver))

    walk(full_name)
    return out


def download(pkg: dict, ver: dict) -> bytes:
    url = ver.get("download_url") or DOWNLOAD_URL.format(owner=pkg["owner"], name=pkg["name"],
                                                         version=ver["version_number"])
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read()


def remove_files(profile: Path, full: str) -> None:
    for route in ("mod", "pak", "overlay"):
        d = profile / ROUTES[route] / full
        if d.is_dir() and not d.is_symlink():
            shutil.rmtree(d)


def install(index: list[dict], full_name: str, profile: Path | None = None, progress=None) -> list[str]:
    profile = profile or profile_dir()
    if full_name in BUILTIN:
        raise ModError(f"{full_name} is part of TotV OS")
    todo = plan(index, full_name, profile)
    mods = [m for m in read_mods_yml(profile)]
    done = []
    for pkg, ver in todo:
        if progress:
            progress(f"Downloading {pkg['full_name']} {ver['version_number']}…")
        data = download(pkg, ver)
        remove_files(profile, pkg["full_name"])
        install_zip(profile, pkg["full_name"], data)
        mods = [m for m in mods if m.get("name") != pkg["full_name"]] + [_entry(pkg, ver)]
        write_mods_yml(profile, mods)
        done.append(f"{pkg['full_name']}-{ver['version_number']}")
    mark_pending(profile, "installed", done)
    return done


def uninstall(full_name: str, profile: Path | None = None) -> None:
    profile = profile or profile_dir()
    if full_name in BUILTIN:
        raise ModError(f"{full_name} is part of TotV OS and cannot be removed")
    mods = read_mods_yml(profile)
    needed = [m["name"] for m in mods if any(d.startswith(full_name + "-") for d in m.get("dependencies", []))
              and m.get("name") != full_name]
    if needed:
        raise ModError(f"{full_name} is needed by {', '.join(needed)}; remove those first")
    remove_files(profile, full_name)
    write_mods_yml(profile, [m for m in mods if m.get("name") != full_name])
    mark_pending(profile, "removed", [full_name])


def updates(index: list[dict], profile: Path | None = None) -> list[str]:
    pk = by_full_name(index)
    out = []
    for name, m in installed(profile).items():
        p = pk.get(name)
        if name not in BUILTIN and p and p["versions"][0]["version_number"] != _version(m):
            out.append(name)
    return out


# Pending changes: applied by restarting TotV OS -----------------------------------------------
def pending_file(profile: Path) -> Path:
    return profile / "totv-pending.json"


def mark_pending(profile: Path, what: str, names: list[str]) -> None:
    if not names:
        return
    f = pending_file(profile)
    try:
        d = json.loads(f.read_text())
    except (OSError, ValueError):
        d = {"installed": [], "removed": []}
    d.setdefault(what, []).extend(names)
    d["since"] = d.get("since") or int(time.time())
    f.write_text(json.dumps(d))


def pending(profile: Path | None = None) -> dict:
    try:
        return json.loads(pending_file(profile or profile_dir()).read_text())
    except (OSError, ValueError):
        return {}


def clear_pending(profile: Path | None = None) -> None:
    try:
        pending_file(profile or profile_dir()).unlink()
    except FileNotFoundError:
        pass
