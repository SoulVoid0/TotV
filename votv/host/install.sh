#!/bin/bash
# TotV OS hook: install the Voices of the Void integration into a TotV OS system.
#
# Called by the TotV OS installer as   /opt/totv/hooks/votv/install.sh /mnt
# with TOTV_ROOT, TOTV_USERNAME, TOTV_OFFLINE=0|1 and TOTV_GAME_ARCHIVE (may be empty).
# Also works on an installed system:   sudo votv/host/install.sh /
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT="${1:-${TOTV_ROOT:-/}}"
ROOT="${ROOT%/}"
OFFLINE="${TOTV_OFFLINE:-0}"
ARCHIVE="${TOTV_GAME_ARCHIVE:-}"
MOD_SRC="$HERE/mod"
[ -d "$MOD_SRC" ] || MOD_SRC="$HERE/../mod"          # running from a repo checkout

user="${TOTV_USERNAME:-}"
if [ -z "$user" ] && [ -f "$ROOT/etc/totv/user.conf" ]; then
    user=$(. "$ROOT/etc/totv/user.conf"; echo "${USERNAME:-}")
fi

in_root() {
    if [ -z "$ROOT" ]; then "$@"; else arch-chroot "$ROOT" "$@"; fi
}

say() { echo "[votv] $*"; }

# 1. Packages ----------------------------------------------------------------------------
mapfile -t pkgs < <(grep -v '^\s*\(#\|$\)' "$HERE/packages.x86_64")
if [ "${VOTV_SKIP_PACKAGES:-0}" = 1 ]; then
    say "skipping ${#pkgs[@]} packages (VOTV_SKIP_PACKAGES=1)"
else
    say "installing ${#pkgs[@]} packages"
    in_root pacman -S --needed --noconfirm "${pkgs[@]}"
fi

# 2. Files ---------------------------------------------------------------------------------
LIB="$ROOT/usr/lib/votv-os"
say "installing files"
install -d "$LIB/python" "$LIB/mods" "$LIB/paks" "$LIB/cfg" "$LIB/shimloader"
rm -rf "$LIB/python/votvos" "$LIB/mods/TotVOS"
cp -r "$HERE/lib/votvos" "$LIB/python/votvos"
find "$LIB/python" -name '__pycache__' -prune -exec rm -rf {} +
cp -r "$MOD_SRC/TotVOS" "$LIB/mods/TotVOS"
touch "$LIB/mods/TotVOS/enabled.txt"

for b in votv-os-session votv-os-bridge votv-pc votv-inventory votv-screen-setup \
         votv-os-launch-game votv-pc-session votv-os-install-game votv-os-fetch-deps; do
    install -Dm755 "$HERE/bin/$b" "$ROOT/usr/bin/$b"
done
for b in votv-os-session-main votv-pc-desktop votv-os-engine-ini; do
    install -Dm755 "$HERE/bin/$b" "$LIB/$b"
done
install -Dm644 "$HERE/config/dxvk.conf" "$LIB/dxvk.conf"
[ -f "$ROOT/etc/totv/votv.json" ] || install -Dm644 "$HERE/config/votv.json" "$ROOT/etc/totv/votv.json"

install -d "$ROOT/usr/share/kwin/scripts"
rm -rf "$ROOT/usr/share/kwin/scripts/votv-os-wm"
cp -r "$HERE/kwin/votv-os-wm" "$ROOT/usr/share/kwin/scripts/votv-os-wm"
for f in "$HERE"/share/applications/*.desktop; do
    install -Dm644 "$f" "$ROOT/usr/share/applications/$(basename "$f")"
done
install -Dm644 "$HERE/share/wayland-sessions/votv-os.desktop" "$ROOT/usr/share/wayland-sessions/votv-os.desktop"
install -Dm644 "$HERE/session.d/50-votv-os.sh" "$ROOT/usr/lib/totv/session.d/50-votv-os.sh"

# Desktop icons on the in-game PC (Plasma's desktop shows ~/Desktop).
install -d "$ROOT/etc/skel/Desktop"
for app in votv-pc votv-screen-setup; do
    install -m755 "$HERE/share/applications/$app.desktop" "$ROOT/etc/skel/Desktop/$app.desktop"
done
if [ -n "$user" ] && home=$(in_root getent passwd "$user" | cut -d: -f6) && [ -n "$home" ]; then
    install -d "$ROOT$home/Desktop"
    for app in votv-pc votv-screen-setup; do
        install -m755 "$HERE/share/applications/$app.desktop" "$ROOT$home/Desktop/$app.desktop"
    done
    in_root chown -R "$user:" "$home/Desktop"
    in_root usermod -aG gamemode "$user" 2>/dev/null || true
fi

# 3. Shimloader ------------------------------------------------------------------------------
if [ -f "$HERE/vendor/shimloader/dwmapi.dll" ]; then
    cp -f "$HERE"/vendor/shimloader/* "$LIB/shimloader/"
elif [ "$OFFLINE" != 1 ]; then
    "$HERE/bin/votv-os-fetch-deps" "$LIB/shimloader" || say "WARNING: shimloader download failed"
else
    say "WARNING: offline install without vendor/shimloader; the mod loads once shimloader is installed (votv-os-fetch-deps)"
fi

# 4. The game -------------------------------------------------------------------------------
if [ -n "$ARCHIVE" ]; then
    say "installing Voices of the Void from $ARCHIVE"
    "$HERE/bin/votv-os-install-game" --root "${ROOT:-/}" ${user:+--owner "$user"} "$ARCHIVE" \
        || say "WARNING: game install failed; later: sudo votv-os-install-game /path/to/game"
fi

# 5. Proton (DXVK) for the game, through LSIW -----------------------------------------------
if [ "$OFFLINE" != 1 ] && [ -n "$user" ] && in_root sh -c 'command -v lsiw' >/dev/null 2>&1; then
    say "downloading GE-Proton for $user (LSIW runners)"
    in_root runuser -u "$user" -- lsiw runners install ge || say "WARNING: GE-Proton download failed; the game will use Wine"
fi

say "done"
