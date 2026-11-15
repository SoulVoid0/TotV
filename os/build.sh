#!/usr/bin/env bash
# Builds the TotV packages and the TotV installer ISO.
#
#   sudo os/build.sh [--online] [--out DIR] [--work DIR]
#
# Needs Arch Linux (or an archlinux container run with --privileged) with
# archiso and base-devel installed. Steps:
#   1. build os/packages/* (lsiw, totv-base) with makepkg
#   2. unless --online: download every package of the installed system
#      (os/target-packages.x86_64, os/optional-packages.x86_64 and the
#      extensions' packages.x86_64) with its dependencies, so the installer
#      works without a network
#   3. make the "totv" repository of all of them
#   4. take archiso's releng profile, add the TotV installer (os/iso) and the
#      repository, and build the ISO with mkarchiso
# Extensions: every <repo>/votv/host (and os/extensions/<name>) that has an
# install.sh is copied into the ISO as /opt/totv/hooks/<name>; the installer
# runs it after installing the base system (see os/README.md).
#
# Output in --out (default ./out): totv-<version>-x86_64.iso, SHA256SUMS and
# repo/ (TotV's own packages as a pacman repository, published by CI as
# release assets).
#
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(cd "$here/.." && pwd)
out=$top/out
work=/tmp/totv-build
offline=1

while (($#)); do
    case $1 in
        --online) offline=0 ;;
        --out) out=$(realpath -m "$2"); shift ;;
        --work) work=$(realpath -m "$2"); shift ;;
        -h|--help) sed -n '2,23s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

((EUID == 0)) || { echo "build.sh must run as root (mkarchiso needs it)" >&2; exit 1; }
for t in pacman makepkg mkarchiso repo-add; do
    command -v "$t" >/dev/null || { echo "build.sh: $t is missing (pacman -S archiso base-devel)" >&2; exit 1; }
done

version=$(sed -n 's/^pkgver=//p' "$here/packages/totv-base/PKGBUILD")
releng=/usr/share/archiso/configs/releng
repo=$work/repo
profile=$work/profile
builder=totvbuild
msg() { printf '\n==> %s\n' "$*"; }

rm -rf "$work"
mkdir -p "$work" "$repo" "$out"

# ---------------------------------------------------------------------------
msg "Building TotV packages"
id "$builder" &>/dev/null || useradd -r -m -d /var/lib/$builder "$builder"
cp -r "$here/packages" "$work/packages"
chown -R "$builder:" "$work/packages"
for dir in "$work"/packages/*/; do
    name=$(basename "$dir")
    # makedepends/depends from the official repositories; TotV's own
    # packages are installed from the ones built before (lsiw before totv-base).
    mapfile -t deps < <(cd "$dir" && bash -c 'source ./PKGBUILD; printf "%s\n" "${makedepends[@]}"')
    ((${#deps[@]})) && pacman -S --needed --noconfirm "${deps[@]}"
    msg "makepkg $name"
    (cd "$dir" && runuser -u "$builder" -- makepkg -f --nodeps --noconfirm)
    cp "$dir"/*.pkg.tar.zst "$repo/"
done
ls -1 "$repo"
# TotV's own packages alone: the repository installed systems use
# ([totv] in their pacman.conf, published by CI as release assets).
own=$work/own-repo
mkdir -p "$own"
cp "$repo"/*.pkg.tar.zst "$own/"
(cd "$own" && repo-add -q totv.db.tar.gz ./*.pkg.tar.zst)

# ---------------------------------------------------------------------------
# The extensions to put in the ISO.
declare -A hooks=()
[[ -f $top/votv/host/install.sh ]] && hooks[votv]=$top/votv/host
for d in "$here"/extensions/*/; do
    [[ -f $d/install.sh ]] && hooks[$(basename "$d")]=${d%/}
done
echo "extensions: ${!hooks[*]:-none}"

list() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$@"; }

if ((offline)); then
    msg "Downloading the installed system's packages for offline installs"
    conf=$work/pacman-download.conf
    cp /etc/pacman.conf "$conf"
    grep -q '^\[multilib\]' "$conf" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$conf"
    db=$work/download-db
    mkdir -p "$db"
    mapfile -t pkgs < <(list "$here/target-packages.x86_64" | grep -vxE 'lsiw|lsiw-control|totv-base')
    for h in "${!hooks[@]}"; do
        [[ -f ${hooks[$h]}/packages.x86_64 ]] && mapfile -t -O "${#pkgs[@]}" pkgs < <(list "${hooks[$h]}/packages.x86_64")
    done
    # lsiw's dependencies come from the official repositories.
    pkgs+=(glibc hicolor-icon-theme)
    pacman --config "$conf" --dbpath "$db" -Syw --noconfirm --cachedir "$repo" "${pkgs[@]}"
    # Optional packages: bundled when the repositories have them.
    while read -r name opt; do
        # shellcheck disable=SC2086
        pacman --config "$conf" --dbpath "$db" -Sw --noconfirm --cachedir "$repo" $opt ||
            echo "warning: option '$name' ($opt) is not bundled; it needs a network at install time"
    done < <(list "$here/optional-packages.x86_64")
fi

msg "Creating the totv repository"
(cd "$repo" && rm -f ./*.sig && repo-add -q totv.db.tar.gz ./*.pkg.tar.zst)
((offline)) && touch "$repo/.complete"

# ---------------------------------------------------------------------------
msg "Assembling the archiso profile"
cp -a "$releng" "$profile"
cp -a "$here/iso/airootfs/." "$profile/airootfs/"
cat "$here/iso/zlogin.append" >>"$profile/airootfs/root/.zlogin"
list "$here/iso/packages.x86_64" >>"$profile/packages.x86_64"
sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"

mkdir -p "$profile/airootfs/etc/totv" "$profile/airootfs/opt/totv"
echo "TOTV_VERSION=$version" >"$profile/airootfs/etc/totv-live-release"
cp "$here/target-packages.x86_64" "$profile/airootfs/etc/totv/target-packages"
cp "$here/optional-packages.x86_64" "$profile/airootfs/etc/totv/optional-packages"
cp -a "$repo" "$profile/airootfs/opt/totv/repo"
for h in "${!hooks[@]}"; do
    mkdir -p "$profile/airootfs/opt/totv/hooks"
    cp -a "${hooks[$h]}" "$profile/airootfs/opt/totv/hooks/$h"
done

# The installer's package sources: only the bundled repository (offline),
# or the bundled repository first and then the Arch mirrors (online).
base_conf() {
    cat <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[totv]
SigLevel = Optional TrustAll
Server = file:///opt/totv/repo
EOF
}
base_conf >"$profile/airootfs/etc/totv/pacman-offline.conf"
{
    base_conf
    printf '\n[core]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n'
} >"$profile/airootfs/etc/totv/pacman-online.conf"
# Offline, every package is in [totv] and unsigned there: trust it.
sed -i 's/^SigLevel = Required DatabaseOptional/SigLevel = Optional TrustAll/' \
    "$profile/airootfs/etc/totv/pacman-offline.conf"

# Name and permissions.
pd=$profile/profiledef.sh
sed -i -e 's/^iso_name=.*/iso_name="totv"/' \
       -e 's/^iso_label=.*/iso_label="TOTV_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"/' \
       -e 's/^iso_publisher=.*/iso_publisher="TotV <https:\/\/github.com\/SoulVoid0\/TotV>"/' \
       -e 's/^iso_application=.*/iso_application="TotV installer"/' \
       -e "s/^iso_version=.*/iso_version=\"$version\"/" "$pd"
echo 'file_permissions+=(["/usr/local/bin/totv-install"]="0:0:755")' >>"$pd"
for h in "${!hooks[@]}"; do
    echo "file_permissions+=([\"/opt/totv/hooks/$h/install.sh\"]=\"0:0:755\")" >>"$pd"
done
# Boot menu entries.
grep -rlZ 'Arch Linux install medium' "$profile"/{efiboot,grub,syslinux} 2>/dev/null |
    xargs -0r sed -i 's/Arch Linux install medium/TotV installer/g'

# ---------------------------------------------------------------------------
msg "Building the ISO"
mkarchiso -v -w "$work/archiso" -o "$work/iso" "$profile"
iso=$(ls "$work"/iso/*.iso)
final="$out/totv-$version-x86_64.iso"
mv "$iso" "$final"
rm -rf "$out/repo"
cp -rL "$own" "$out/repo"   # -L: GitHub release assets cannot be symlinks
(cd "$out" && sha256sum "$(basename "$final")" >SHA256SUMS)
msg "Done: $final"
cat "$out/SHA256SUMS"
