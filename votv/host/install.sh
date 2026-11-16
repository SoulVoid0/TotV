#!/bin/bash
# Install the Voices of the Void integration of TotV OS.
#
#   install.sh --files-only DESTDIR   only the files (the votv-os package's package())
#   install.sh [ROOT]                 the files and the setup of a system root (the system
#                                     image build, the installer's package fallback, or
#                                     `sudo votv/host/install.sh /` on a running TotV)
#
# The setup: the votv system user and /.VotV, the services (totvd, totv-shell on tty1,
# the daily update check), Wine for LSIW (always: the game needs it), shimloader, the game
# in /.VotV/<version> (TOTV_GAME_ARCHIVE=<zip or folder>, or downloaded with
# VOTV_FETCH=1), r2modman in /.VotV/r2modman with the Default profile, and the users of
# the system (TOTV_USERNAME or /etc/totv/user.conf) in group votv.
# VOTV_SKIP_PACKAGES=1 skips pacman; TOTV_OFFLINE=1 skips every download.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
FILES_ONLY=0
[ "${1:-}" = --files-only ] && { FILES_ONLY=1; shift; }
ROOT="${1:-${TOTV_ROOT:-/}}"
ROOT="${ROOT%/}"
OFFLINE="${TOTV_OFFLINE:-0}"
ARCHIVE="${TOTV_GAME_ARCHIVE:-}"
MOD_SRC="$HERE/mod"
[ -d "$MOD_SRC" ] || MOD_SRC="$HERE/../mod"          # running from a repo checkout

say() { echo "[votv] $*"; }
in_root() { if [ -z "$ROOT" ]; then "$@"; else arch-chroot "$ROOT" "$@"; fi; }

# 1. Files ---------------------------------------------------------------------------------
LIB="$ROOT/usr/lib/votv-os"
say "installing files into ${ROOT:-/}"
install -d "$LIB/python" "$LIB/mods" "$LIB/shimloader" "$ROOT/usr/bin"
rm -rf "$LIB/python/votvos" "$LIB/mods/TotVOS"
cp -r "$HERE/lib/votvos" "$LIB/python/votvos"
find "$LIB/python" -name '__pycache__' -prune -exec rm -rf {} +
cp -r "$MOD_SRC/TotVOS" "$LIB/mods/TotVOS"
touch "$LIB/mods/TotVOS/enabled.txt"
[ -f "$HERE/vendor/shimloader/dwmapi.dll" ] && cp -f "$HERE"/vendor/shimloader/* "$LIB/shimloader/"

for b in votv-os-session votv-pc-session votv-os-launch-game votv-os-install-game votv-os-fetch-deps \
         votv-os-game votv-os-r2modman votv-wayland-socket; do
    install -Dm755 "$HERE/bin/$b" "$ROOT/usr/bin/$b"
done
for b in votv-os-session-main votv-pc-desktop votv-os-engine-ini; do
    install -Dm755 "$HERE/bin/$b" "$LIB/$b"
done
# Python entry points: name -> module:function.
while read -r name target; do
    mod=${target%%:*}; fn=${target#*:}
    cat > "$ROOT/usr/bin/$name" <<EOS
#!/usr/bin/python3
import os, sys
sys.path.insert(0, os.environ.get("VOTV_OS_PYTHON", "/usr/lib/votv-os/python"))
from votvos.$mod import $fn
sys.exit($fn($( [[ $fn == ctl_main ]] && echo 'sys.argv[1:]' )))
EOS
    chmod 755 "$ROOT/usr/bin/$name"
done <<'EOT'
votv-os-bridge bridge:main
votv-pc apps:pc_main
votv-inventory apps:inventory_main
votv-screen-setup apps:setup_main
votv-login desktop:greeter_main
votv-pc-agent desktop:agent_main
votv-logout desktop:logout_main
totv-updater desktop:updater_main
votv-os-ctl desktop:ctl_main
totvd totvd:main
votv-mods desktop:mods_main
EOT
cat > "$ROOT/usr/bin/votv-saves" <<'EOS'
#!/usr/bin/python3
"""votv-saves: the VotV Saves app; `votv-saves list | load NAME | home | new TITLE MODE` from a shell."""
import os, sys
sys.path.insert(0, os.environ.get("VOTV_OS_PYTHON", "/usr/lib/votv-os/python"))
from votvos.desktop import saves_cli, saves_main
sys.exit(saves_cli(sys.argv[1:]) if len(sys.argv) > 1 else saves_main())
EOS
chmod 755 "$ROOT/usr/bin/votv-saves"

install -Dm644 "$HERE/config/dxvk.conf" "$LIB/dxvk.conf"
install -Dm644 "$HERE/config/votv.json" "$ROOT/usr/share/votv-os/votv.json"
install -Dm644 "$HERE/config/pipewire/totv-pulse.conf" "$ROOT/usr/share/votv-os/pipewire-pulse-totv.conf"
install -Dm644 "$HERE/config/sysusers.conf" "$ROOT/usr/lib/sysusers.d/votv-os.conf"
install -Dm644 "$HERE/config/tmpfiles.conf" "$ROOT/usr/lib/tmpfiles.d/votv-os.conf"
for u in "$HERE"/systemd/*; do install -Dm644 "$u" "$ROOT/usr/lib/systemd/system/$(basename "$u")"; done
for p in "$HERE"/pam/*; do install -Dm644 "$p" "$ROOT/etc/pam.d/$(basename "$p")"; done
install -Dm755 "$HERE/update.d/50-votv" "$ROOT/usr/lib/totv/update.d/50-votv"

install -d "$ROOT/usr/share/kwin/scripts"
rm -rf "$ROOT/usr/share/kwin/scripts/votv-os-wm"
cp -r "$HERE/kwin/votv-os-wm" "$ROOT/usr/share/kwin/scripts/votv-os-wm"
for f in "$HERE"/share/applications/*.desktop; do
    install -Dm644 "$f" "$ROOT/usr/share/applications/$(basename "$f")"
done
# Icons on every user's PC desktop (Plasma's desktop shows ~/Desktop).
DESKTOP_APPS="votv-pc votv-saves votv-mods r2modman votv-screen-setup totv-updater votv-restart-game votv-logout"
install -d "$ROOT/etc/skel/Desktop"
for app in $DESKTOP_APPS; do
    install -m755 "$HERE/share/applications/$app.desktop" "$ROOT/etc/skel/Desktop/$app.desktop"
done
[ "$FILES_ONLY" = 1 ] && { say "files done"; exit 0; }

# 2. Packages -------------------------------------------------------------------------------
mapfile -t pkgs < <(grep -v '^\s*\(#\|$\)' "$HERE/packages.x86_64")
if [ "${VOTV_SKIP_PACKAGES:-0}" = 1 ]; then
    say "skipping ${#pkgs[@]} packages (VOTV_SKIP_PACKAGES=1)"
else
    say "installing ${#pkgs[@]} packages (Wine included: the game needs it)"
    in_root pacman -S --needed --noconfirm "${pkgs[@]}"
fi
[ -f "$ROOT/etc/totv/votv.json" ] || install -Dm644 "$HERE/config/votv.json" "$ROOT/etc/totv/votv.json"
[ "${VOTV_SKIP_PACKAGES:-0}" = 1 ] && [ ! -x "$ROOT/usr/bin/systemd-sysusers" ] && { say "no systemd in ${ROOT:-/}; setup skipped"; exit 0; }

# 3. The votv user, /.VotV, the services -----------------------------------------------------
say "system user, /.VotV and services"
in_root systemd-sysusers
in_root systemd-tmpfiles --create /usr/lib/tmpfiles.d/votv-os.conf || true
install -d "$ROOT/var/lib/votv/.config/pipewire/pipewire-pulse.conf.d"
install -m644 "$HERE/config/pipewire/totv-pulse.conf" "$ROOT/var/lib/votv/.config/pipewire/pipewire-pulse.conf.d/totv.conf"
in_root chown -R votv:votv /var/lib/votv /.VotV
in_root systemctl enable totvd.service totv-shell.service totv-update-check.timer
in_root systemctl set-default graphical.target
in_root systemctl disable getty@tty1.service 2>/dev/null || true
# The game's user may run gamemode; logind gives the shell the seat.
users="${TOTV_USERNAME:-}"
[ -z "$users" ] && [ -f "$ROOT/etc/totv/user.conf" ] && users=$(. "$ROOT/etc/totv/user.conf"; echo "${USERNAME:-}")
for u in $users; do
    in_root usermod -aG votv,gamemode "$u" 2>/dev/null || in_root usermod -aG votv "$u" || true
    home=$(in_root getent passwd "$u" | cut -d: -f6)
    if [ -n "$home" ]; then
        install -d "$ROOT$home/Desktop"
        for app in $DESKTOP_APPS; do install -m755 "$HERE/share/applications/$app.desktop" "$ROOT$home/Desktop/"; done
        in_root chown -R "$u:" "$home/Desktop"
    fi
done

# 4. LSIW for the game: Wine (always installed), GE-Proton when there is a network --------------
# The votv user's own LSIW settings: Wine from PATH, no update check. The game reaches the
# system through Z:\ (= /). /users/votv and /users/steamuser (Proton's profile, C:\users\
# steamuser, since C: is /) are the game user's home: it must be able to write there.
install -d "$ROOT/var/lib/votv/.config/lsiw"
cat > "$ROOT/var/lib/votv/.config/lsiw/lsiw.conf" <<'EOS'
# LSIW for the votv system user (Voices of the Void on TotV OS), from votv-os.
[engine]
wine = auto

[steam]
full_c_drive = false

[update]
check = false
EOS
ln -sfn /var/lib/votv "$ROOT/users/votv" 2>/dev/null || true
# Proton's profile C:\users\steamuser is /users/steamuser (C: is /): the game's user's.
ln -sfn /var/lib/votv "$ROOT/users/steamuser" 2>/dev/null || true
in_root chown -h votv:cdrive /users/steamuser 2>/dev/null || true
in_root chown -R votv:votv /var/lib/votv
in_root chown -h votv:cdrive /users/votv 2>/dev/null || true
if [ "$OFFLINE" != 1 ]; then
    say "downloading GE-Proton for the game (LSIW runners; Wine stays the fallback)"
    in_root runuser -u votv -- env HOME=/var/lib/votv lsiw runners install ge || say "WARNING: GE-Proton download failed; the game uses Wine"
fi

# 5. Shimloader --------------------------------------------------------------------------------
if [ ! -f "$LIB/shimloader/dwmapi.dll" ]; then
    if [ "$OFFLINE" != 1 ]; then
        "$HERE/bin/votv-os-fetch-deps" "$LIB/shimloader" || say "WARNING: shimloader download failed"
    else
        say "WARNING: no shimloader staged; run: sudo votv-os-fetch-deps /usr/lib/votv-os/shimloader"
    fi
fi

# 6. The game ------------------------------------------------------------------------------------
if [ -n "$ARCHIVE" ]; then
    say "installing Voices of the Void from $ARCHIVE"
    "$HERE/bin/votv-os-install-game" --root "${ROOT:-/}" ${VOTV_VERSION:+--version "$VOTV_VERSION"} "$ARCHIVE"
elif [ "${VOTV_FETCH:-0}" = 1 ] && [ "$OFFLINE" != 1 ]; then
    say "downloading Voices of the Void"
    PATH="$HERE/bin:$PATH" VOTV_ROOT="$ROOT/.VotV" "$HERE/bin/votv-os-game" install --root "${ROOT:-/}" \
        ${VOTV_VERSION:+--version "$VOTV_VERSION"} || say "WARNING: the game download failed (later: sudo votv-os-game install)"
elif [ ! -e "$ROOT/.VotV/current" ]; then
    say "WARNING: Voices of the Void is not installed yet (sudo votv-os-game install)"
fi
[ -e "$ROOT/.VotV/current" ] && "$HERE/bin/votv-os-install-game" --root "${ROOT:-/}" --shimloader-only

# 7. r2modman ------------------------------------------------------------------------------------
if [ ! -x "$ROOT/.VotV/r2modman/app/r2modman" ] && [ "$OFFLINE" != 1 ]; then
    "$HERE/bin/votv-os-r2modman" install --root "${ROOT:-/}" || say "WARNING: r2modman download failed (later: sudo votv-os-r2modman install)"
fi
"$HERE/bin/votv-os-r2modman" seed --root "${ROOT:-/}"
say "done"
