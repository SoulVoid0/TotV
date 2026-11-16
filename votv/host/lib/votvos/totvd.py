"""totvd: the TotV system helper (root), on the socket /run/totv/totvd.sock.

The game and r2modman run as the votv system user (they are part of the system); the
people who use TotV log in on the in-game PC. totvd does what needs root, for callers it
knows by their socket credentials (SO_PEERCRED):

  login {user, password}   from the greeter (votv): checks the password with PAM
                           (service totv-login), ends another user's desktop, starts
                           totv-desktop@<user>.service (the user's KDE desktop on the
                           in-game PC) and writes /run/totv/votv-os/session.json
  autologin                from the bridge (votv), when /etc/totv/totv.conf says
                           AUTOLOGIN=yes: the installer's user, once per boot
  logout                   from the logged-in user (or votv): stops the desktop
  ended {user}             from totv-desktop@.service's ExecStopPost (root)
  r2modman                 from the logged-in user: r2modman (as votv) on their desktop
  restart-game             from the logged-in user or votv: the game restarts
  apply-mods               from the logged-in user: the running world is saved and TotV
                           restarts, so the game starts with the mods VotV Mods changed
  update / update-status   from a logged-in user of group wheel: totv-update.service
  status                   anyone
"""
from __future__ import annotations

import ctypes
import ctypes.util
import grp
import json
import os
import pwd
import re
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import paths

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
RT = Path(os.environ.get("VOTV_OS_RUNTIME_LINUX", "/run/totv/votv-os"))
SESSION = RT / "session.json"


# PAM ---------------------------------------------------------------------------------------
class _PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class _PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


_CONV_FUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(_PamMessage)),
                              ctypes.POINTER(ctypes.POINTER(_PamResponse)), ctypes.c_void_p)


class _PamConv(ctypes.Structure):
    _fields_ = [("conv", _CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


def pam_check(service: str, user: str, password: str) -> tuple[bool, str]:
    """True when PAM accepts the password and the account (pam_authenticate + pam_acct_mgmt)."""
    lib = ctypes.util.find_library("pam")
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    if not lib:
        return False, "PAM is not available"
    pam = ctypes.CDLL(lib)
    libc.calloc.restype = ctypes.c_void_p
    libc.strdup.restype = ctypes.c_void_p
    pw = password.encode()

    @_CONV_FUNC
    def conv(n, msgs, resp, _data):
        arr = libc.calloc(n, ctypes.sizeof(_PamResponse))
        if not arr:
            return 5   # PAM_BUF_ERR
        resp[0] = ctypes.cast(arr, ctypes.POINTER(_PamResponse))
        for i in range(n):
            if msgs[i].contents.msg_style in (1, 2):   # PROMPT_ECHO_OFF / ON
                resp[0][i].resp = ctypes.cast(libc.strdup(pw), ctypes.c_char_p)
                resp[0][i].resp_retcode = 0
        return 0

    handle = ctypes.c_void_p()
    pc = _PamConv(conv, None)
    pam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(_PamConv), ctypes.POINTER(ctypes.c_void_p)]
    pam.pam_strerror.restype = ctypes.c_char_p
    pam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
    rc = pam.pam_start(service.encode(), user.encode(), ctypes.byref(pc), ctypes.byref(handle))
    if rc != 0:
        return False, "PAM could not start"
    try:
        rc = pam.pam_authenticate(handle, 0)
        if rc == 0:
            rc = pam.pam_acct_mgmt(handle, 0)
        err = "" if rc == 0 else (pam.pam_strerror(handle, rc) or b"").decode(errors="replace")
        return rc == 0, err
    finally:
        pam.pam_end(handle, rc)


# Sessions -------------------------------------------------------------------------------------
def systemctl(*args: str) -> tuple[int, str]:
    p = subprocess.run(["systemctl", *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def session_user() -> str | None:
    try:
        u = json.loads(SESSION.read_text()).get("user")
        return u if isinstance(u, str) and USER_RE.match(u) else None
    except (OSError, ValueError, AttributeError):
        return None


def write_session(user: str | None) -> None:
    if user is None:
        try:
            SESSION.unlink()
        except FileNotFoundError:
            pass
        return
    pw = pwd.getpwnam(user)
    votv = pwd.getpwnam(paths.SYSTEM_USER)
    tmp = RT / ".session.json.tmp"
    tmp.write_text(json.dumps({"user": user, "uid": pw.pw_uid, "since": int(time.time())}))
    os.chown(tmp, votv.pw_uid, votv.pw_gid)
    tmp.chmod(0o644)
    os.replace(tmp, SESSION)


def is_login_user(user: str) -> bool:
    if not USER_RE.match(user or ""):
        return False
    try:
        p = pwd.getpwnam(user)
    except KeyError:
        return False
    if not (1000 <= p.pw_uid < 60000) or p.pw_shell.endswith(("nologin", "false")):
        return False
    try:
        return user in grp.getgrnam("votv").gr_mem
    except KeyError:
        return True


class Helper:
    def __init__(self):
        self.lock = threading.Lock()
        self.fails: dict[str, list[float]] = {}
        self.autologin_used = False
        self.votv_uid = pwd.getpwnam(paths.SYSTEM_USER).pw_uid

    def start_desktop(self, user: str) -> dict:
        cur = session_user()
        if cur and cur != user:
            systemctl("stop", f"totv-desktop@{cur}.service")
        pw = pwd.getpwnam(user)
        d = paths.PC_DIR / user
        d.mkdir(parents=True, exist_ok=True)
        os.chown(d, pw.pw_uid, grp.getgrnam("votv").gr_gid)
        d.chmod(0o750)
        write_session(user)
        rc, out = systemctl("start", "--no-block", f"totv-desktop@{user}.service")
        if rc != 0:
            write_session(None)
            return {"ok": False, "error": f"the desktop did not start: {out}"}
        return {"ok": True, "user": user}

    def handle(self, req: dict, uid: int) -> dict:
        op = req.get("op")
        caller = pwd.getpwuid(uid).pw_name if uid >= 0 else "?"
        cur = session_user()
        if op == "status":
            return {"ok": True, "user": cur}
        if op == "login":
            if uid not in (0, self.votv_uid):
                return {"ok": False, "error": "only the login screen logs people in"}
            user = str(req.get("user", "")).strip()
            if not is_login_user(user):
                time.sleep(1.5)
                return {"ok": False, "error": "Unknown user or wrong password"}
            recent = [t for t in self.fails.get(user, []) if time.time() - t < 60]
            if len(recent) >= 5:
                return {"ok": False, "error": "Too many attempts; wait a minute"}
            ok, err = pam_check("totv-login", user, str(req.get("password", "")))
            if not ok:
                self.fails[user] = recent + [time.time()]
                time.sleep(1.5)
                return {"ok": False, "error": "Unknown user or wrong password"}
            self.fails.pop(user, None)
            return self.start_desktop(user)
        if op == "autologin":
            if uid not in (0, self.votv_uid) or self.autologin_used or cur:
                return {"ok": False, "error": "not now"}
            conf = paths.read_kv(paths.TOTV_CONF)
            user = paths.read_kv(paths.USER_CONF).get("USERNAME", "")
            if conf.get("AUTOLOGIN") != "yes" or not is_login_user(user):
                return {"ok": False, "error": "autologin is off"}
            self.autologin_used = True
            return self.start_desktop(user)
        if op == "logout":
            if not cur:
                return {"ok": True}
            if uid not in (0, self.votv_uid) and caller != cur:
                return {"ok": False, "error": "only the logged-in user logs out"}
            write_session(None)
            systemctl("stop", "--no-block", f"totv-desktop@{cur}.service")
            systemctl("stop", "--no-block", f"totv-r2modman@{cur}.service")
            return {"ok": True}
        if op == "ended":
            if uid != 0:
                return {"ok": False, "error": "not allowed"}
            if cur == req.get("user"):
                write_session(None)
                systemctl("stop", "--no-block", f"totv-r2modman@{cur}.service")
            return {"ok": True}
        if op == "r2modman":
            if not cur or caller != cur:
                return {"ok": False, "error": "log in first"}
            rc, out = systemctl("start", "--no-block", f"totv-r2modman@{cur}.service")
            return {"ok": rc == 0, "error": out if rc else None}
        if op == "restart-game":
            if uid not in (0, self.votv_uid) and caller != cur:
                return {"ok": False, "error": "log in first"}
            (RT / "restart-game").touch()
            return {"ok": True}
        if op == "apply-mods":
            if uid not in (0, self.votv_uid) and caller != cur:
                return {"ok": False, "error": "log in first"}
            # Save the running world through the mod, give it a moment, then restart the OS.
            try:
                with open(RT / "host-commands.jsonl", "a") as f:
                    f.write(json.dumps({"type": "save_now", "req": 0}) + "\n")
            except OSError:
                pass
            threading.Thread(target=lambda: (time.sleep(4), systemctl("reboot")), daemon=True).start()
            return {"ok": True}
        if op in ("update", "update-status"):
            admins = grp.getgrnam("wheel").gr_mem if op == "update" else []
            if op == "update" and uid != 0 and (caller != cur or caller not in admins):
                return {"ok": False, "error": "updating needs a logged-in administrator (group wheel)"}
            if op == "update":
                rc, out = systemctl("start", "--no-block", "totv-update.service")
                return {"ok": rc == 0, "error": out if rc else None}
            rc, out = systemctl("is-active", "totv-update.service")
            return {"ok": True, "state": out.splitlines()[0] if out else "unknown"}
        return {"ok": False, "error": f"unknown request {op!r}"}

    def serve_one(self, conn: socket.socket) -> None:
        with conn:
            try:
                creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
                _pid, uid, _gid = struct.unpack("3i", creds)
                conn.settimeout(10)
                buf = b""
                while not buf.endswith(b"\n") and len(buf) < 65536:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                req = json.loads(buf or b"{}")
                if not isinstance(req, dict):
                    raise ValueError("not an object")
                with self.lock:
                    resp = self.handle(req, uid)
            except (OSError, ValueError, KeyError) as e:
                resp = {"ok": False, "error": str(e)}
            try:
                conn.sendall((json.dumps(resp) + "\n").encode())
            except OSError:
                pass


def ensure_proton_profile() -> None:
    """C:\\users\\steamuser (Proton's Windows profile) is /users/steamuser, because C: is /
    on TotV. The game runs as votv, so it must be votv's home; older installs pointed it at
    the installer's user, and Proton could not create the game's prefix."""
    link = Path("/users/steamuser")
    try:
        votv = pwd.getpwnam(paths.SYSTEM_USER)
        if link.is_symlink() and os.readlink(link) == votv.pw_dir:
            return
        if link.exists() and not link.is_symlink():
            return   # a real folder someone made: leave it
        tmp = Path("/users/.steamuser.totvd")
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        tmp.symlink_to(votv.pw_dir)
        os.lchown(tmp, votv.pw_uid, grp.getgrnam("cdrive").gr_gid)
        os.replace(tmp, link)
        print(f"totvd: /users/steamuser -> {votv.pw_dir}", file=sys.stderr)
    except (KeyError, OSError) as e:
        print(f"totvd: cannot fix /users/steamuser: {e}", file=sys.stderr)


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--ended":
        from .bridge import totvd
        totvd({"op": "ended", "user": sys.argv[2]}, timeout=10)
        return 0
    if os.geteuid() != 0:
        print("totvd must run as root", file=sys.stderr)
        return 1
    RT.mkdir(parents=True, exist_ok=True)
    ensure_proton_profile()
    helper = Helper()
    path = paths.LOGIN_SOCKET
    if os.environ.get("LISTEN_FDS") == "1":
        srv = socket.socket(fileno=3)
    else:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(path))
        os.chown(path, 0, grp.getgrnam("votv").gr_gid)
        path.chmod(0o660)
        srv.listen(8)
    # A session left over from before a restart of totvd (or of the machine) is gone.
    cur = session_user()
    if cur:
        rc, _ = systemctl("is-active", "--quiet", f"totv-desktop@{cur}.service")
        if rc != 0:
            write_session(None)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=helper.serve_one, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
