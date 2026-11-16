#!/usr/bin/env bash
# Builds the TotV system image: the whole installed OS (Arch Linux, KDE Plasma for the
# in-game PC, LSIW with Wine, Voices of the Void in /.VotV/<version>, r2modman in
# /.VotV/r2modman with the TotVOS mod) as one squashfs, inside an ISO 9660 image.
#
#   sudo os/system/build-system.sh --repo DIR [--out DIR] [--work DIR] [--game ZIP|--no-game]
#
# --repo   the [totv] packages built by os/build.sh (out/repo: lsiw, totv-base, votv-os)
# --game   a Voices of the Void zip to put in /.VotV (default: downloaded from itch.io by
#          votv-os-game; VOTV_URL=<zip url> or ITCH_API_KEY are honoured)
# --no-game  leave the game out (the installed system downloads it: sudo votv-os-game install)
#
# Output in --out (default ./out):
#   totv-system-<version>-x86_64.iso            the image (can be larger than 2 GiB)
#   totv-system-<version>-x86_64.iso.part00 ... the same image in parts of at most
#                                              1900 MiB (GitHub release assets must be
#                                              under 2 GiB); the installer merges them
#   totv-system-<version>-x86_64.iso.parts      the index: each part's size and SHA-256,
#                                              and the whole image's SHA-256
# Needs Arch Linux (or archlinux:latest --privileged) with arch-install-scripts,
# squashfs-tools and libisoburn (xorriso).
#
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(cd "$here/../.." && pwd)
out=$top/out
work=/tmp/totv-system
repo=
game=
nogame=0
part_mib=${TOTV_PART_MIB:-1900}

while (($#)); do
    case $1 in
        --repo) repo=$(realpath "$2"); shift ;;
        --out) out=$(realpath -m "$2"); shift ;;
        --work) work=$(realpath -m "$2"); shift ;;
        --game) game=$(realpath "$2"); shift ;;
        --no-game) nogame=1 ;;
        -h|--help) sed -n '2,25s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "build-system.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
((EUID == 0)) || { echo "build-system.sh must run as root" >&2; exit 1; }
[[ -n $repo && -f $repo/totv.db.tar.gz ]] || { echo "build-system.sh: --repo DIR with totv.db.tar.gz (from os/build.sh) is required" >&2; exit 2; }
for t in pacstrap arch-chroot mksquashfs xorriso; do
    command -v "$t" >/dev/null || { echo "build-system.sh: $t is missing (pacman -S arch-install-scripts squashfs-tools libisoburn)" >&2; exit 1; }
done

version=$(sed -n 's/^pkgver=//p' "$top/os/packages/totv-base/PKGBUILD")
name="totv-system-$version-x86_64"
root=$work/root
msg() { printf '\n==> %s\n' "$*"; }
list() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$@"; }

cleanup() {
    umount -R "$root" 2>/dev/null || true
}
trap cleanup EXIT
rm -rf "$work"
mkdir -p "$root" "$out"

# ---------------------------------------------------------------------------
msg "Installing the system into $root"
conf=$work/pacman.conf
cp /etc/pacman.conf "$conf"
grep -q '^\[multilib\]' "$conf" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$conf"
printf '\n[totv]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$repo" >>"$conf"
mapfile -t pkgs < <(list "$top/os/target-packages.x86_64" "$top/votv/host/packages.x86_64"; echo votv-os)
pacstrap -C "$conf" -K -c "$root" "${pkgs[@]}"

# The installed system's pacman: Arch, multilib, and [totv] from GitHub releases (updates).
grep -q '^\[multilib\]' "$root/etc/pacman.conf" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$root/etc/pacman.conf"
grep -q '^\[totv\]' "$root/etc/pacman.conf" || cat >>"$root/etc/pacman.conf" <<'EOF2'

# TotV's own packages (lsiw, totv-base, votv-os), published by each TotV release.
[totv]
SigLevel = Optional TrustAll
Server = https://github.com/SoulVoid0/TotV/releases/latest/download
EOF2

# ---------------------------------------------------------------------------
msg "Setting up Voices of the Void, r2modman and the services"
gargs=()
if [[ -n $game ]]; then
    mkdir -p "$root/var/tmp/totv-game"
    cp "$game" "$root/var/tmp/totv-game/"
    gargs=(TOTV_GAME_ARCHIVE="/var/tmp/totv-game/$(basename "$game")")
fi
fetch=1; ((nogame)) && fetch=0; [[ -n $game ]] && fetch=0
mount --bind "$root" "$root"   # arch-chroot wants a mount point
arch-chroot "$root" env VOTV_SKIP_PACKAGES=1 TOTV_OFFLINE=0 VOTV_FETCH=$fetch "${gargs[@]}" \
    ${VOTV_URL:+VOTV_URL="$VOTV_URL"} ${ITCH_API_KEY:+ITCH_API_KEY="$ITCH_API_KEY"} \
    bash /usr/share/votv-os/host/install.sh /
rm -rf "$root/var/tmp/totv-game"
umount "$root"
game_version=$(readlink "$root/.VotV/current" 2>/dev/null || echo none)
r2_version=$(cat "$root/.VotV/r2modman/app/.version" 2>/dev/null || echo none)
echo "game: $game_version, r2modman: $r2_version"

# ---------------------------------------------------------------------------
msg "Making it generic (each install sets its own machine, users and keys)"
arch-chroot "$root" systemctl enable NetworkManager.service systemd-timesyncd.service
: >"$root/etc/machine-id"
rm -f "$root"/etc/ssh/ssh_host_* "$root/var/lib/systemd/random-seed"
rm -rf "$root/etc/pacman.d/gnupg"            # the installer runs pacman-key --init/--populate
rm -rf "$root"/var/cache/pacman/pkg/* "$root"/var/log/*.log "$root"/tmp/* "$root"/root/.cache
rm -f "$root/boot/"initramfs-*.img           # built for the target disk by the installer
cat >"$root/etc/totv/system-image" <<EOF2
TOTV_VERSION=$version
GAME_VERSION=$game_version
R2MODMAN_VERSION=$r2_version
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF2
arch-chroot "$root" pacman -Q >"$work/packages.txt"

# ---------------------------------------------------------------------------
msg "Compressing"
iso_tree=$work/iso/totv-system
mkdir -p "$iso_tree"
mksquashfs "$root" "$iso_tree/rootfs.sfs" -comp zstd -Xcompression-level 19 -b 1M -noappend \
    -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'
installed=$(du -sb --exclude=proc --exclude=sys --exclude=dev --exclude=run "$root" | cut -f1)
cp "$work/packages.txt" "$iso_tree/packages.txt"
cat >"$iso_tree/manifest.json" <<EOF2
{"name": "TotV system image", "version": "$version", "game": "$game_version",
 "r2modman": "$r2_version", "installed_bytes": $installed,
 "rootfs": "totv-system/rootfs.sfs", "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF2

iso=$out/$name.iso
rm -f "$iso" "$iso".part* "$iso.parts"
# -iso-level 3: files over 4 GiB (rootfs.sfs) in several extents; Linux mounts them.
xorriso -as mkisofs -iso-level 3 -R -J -joliet-long -V "TOTV_SYS_${version//./_}" \
    -publisher "TotV <https://github.com/SoulVoid0/TotV>" -o "$iso" "$work/iso"

msg "Splitting into parts of $part_mib MiB"
split -b "${part_mib}M" -d -a 2 "$iso" "$iso.part"
{
    echo "# TotV system image $version: the parts of $name.iso, in order (size sha256 name)"
    echo "image $(stat -c %s "$iso") $(sha256sum "$iso" | cut -d' ' -f1) $name.iso"
    for p in "$iso".part*; do echo "part $(stat -c %s "$p") $(sha256sum "$p" | cut -d' ' -f1) $(basename "$p")"; done
} >"$iso.parts"
cat "$iso.parts"
rm -rf "$work"
msg "Done: $iso ($(du -h "$iso" | cut -f1)), $(ls "$iso".part* | wc -l) part(s)"
