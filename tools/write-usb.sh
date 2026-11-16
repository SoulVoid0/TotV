#!/usr/bin/env bash
# Writes the TotV installer ISO to a USB stick (Linux).
#
#   sudo tools/write-usb.sh totv-0.2.0-x86_64.iso            lists USB disks
#   sudo tools/write-usb.sh totv-0.2.0-x86_64.iso /dev/sdX   writes it
#   sudo tools/write-usb.sh totv-0.2.0-x86_64.iso /dev/sdX --system DIR
#        also adds a TOTV_DATA partition (exFAT) after the installer with the system
#        image from DIR (totv-system-*.iso.parts and its .partNN files, or the whole
#        .iso): the installer then installs without a network. A 16 GB stick or larger.
#
# Without --system the installer finds the system image on any other drive, or
# downloads its parts. On Windows or macOS use balenaEtcher or Rufus (DD mode), and
# copy the system image parts to any USB stick.
# SPDX-License-Identifier: MIT
set -euo pipefail

iso=${1:-}
dev=${2:-}
sysdir=
[[ ${3:-} == --system ]] && sysdir=$(realpath "${4:?--system needs a folder}")
[[ -f $iso ]] || { sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 2; }
sysfiles=()
if [[ -n $sysdir ]]; then
    mapfile -t sysfiles < <(find "$sysdir" -maxdepth 1 -type f \( -name 'totv-system-*.iso.part*' -o -name 'totv-system-*.iso' \) | sort)
    ((${#sysfiles[@]})) || { echo "no totv-system-*.iso(.parts/.partNN) in $sysdir" >&2; exit 1; }
    for t in sgdisk sfdisk mkfs.exfat partprobe; do
        command -v "$t" >/dev/null || { echo "$t is missing (gptfdisk, util-linux, exfatprogs, parted)" >&2; exit 1; }
    done
fi

if [[ -f $(dirname "$iso")/SHA256SUMS ]]; then
    echo "Checking $iso against SHA256SUMS..."
    (cd "$(dirname "$iso")" && grep " $(basename "$iso")\$" SHA256SUMS | sha256sum -c -)
fi

if [[ -z $dev ]]; then
    echo "USB / removable disks:"
    lsblk -dpo NAME,SIZE,MODEL,TRAN,RM | awk 'NR==1 || $4=="usb" || $5=="1"'
    echo "Run again with the disk, e.g.: sudo $0 $iso /dev/sdX"
    exit 0
fi

[[ -b $dev ]] || { echo "$dev is not a block device" >&2; exit 1; }
[[ $(lsblk -dno TYPE "$dev") == disk ]] || { echo "$dev is a partition; give the whole disk (e.g. /dev/sdb)" >&2; exit 1; }
tran=$(lsblk -dno TRAN "$dev" | tr -d ' '); rm=$(lsblk -dno RM "$dev" | tr -d ' ')
if [[ $tran != usb && $rm != 1 ]]; then
    echo "$dev is not a USB or removable disk; refusing (it may be your system disk)." >&2
    exit 1
fi
((EUID == 0)) || { echo "run with sudo" >&2; exit 1; }

lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$dev"
read -r -p "Erase $dev and write $iso to it? Type YES: " answer
[[ $answer == YES ]] || { echo "Cancelled."; exit 1; }

for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
dd if="$iso" of="$dev" bs=4M status=progress oflag=direct conv=fsync
sync

if [[ -n $sysdir ]]; then
    need=$(du -cb "${sysfiles[@]}" | tail -n1 | cut -f1)
    echo "Adding the TOTV_DATA partition with the system image ($((need / 1024 / 1024)) MiB)..."
    partprobe "$dev" || true
    table=$(sfdisk -J "$dev" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["label"])')
    before=$(lsblk -lnpo NAME "$dev" | tail -n +2 | sort)
    if [[ $table == gpt ]]; then
        sgdisk -e "$dev" >/dev/null                 # the backup GPT to the end of the stick
        sgdisk -n 0:0:0 -t 0:0700 -c 0:TOTV_DATA "$dev" >/dev/null
    else
        echo ',,7' | sfdisk --append --no-reread "$dev" >/dev/null
    fi
    partprobe "$dev" || true
    udevadm settle || true
    sleep 1
    part=$(comm -13 <(echo "$before") <(lsblk -lnpo NAME "$dev" | tail -n +2 | sort) | head -n1)
    [[ -b $part ]] || { echo "the new partition did not appear" >&2; exit 1; }
    mkfs.exfat -n TOTV_DATA "$part" >/dev/null
    mnt=$(mktemp -d)
    mount "$part" "$mnt"
    avail=$(df -B1 --output=avail "$mnt" | tail -n1)
    if ((avail < need)); then
        umount "$mnt"; echo "the stick is too small for the system image ($need bytes needed)" >&2; exit 1
    fi
    cp -v "${sysfiles[@]}" "$mnt/"
    sync
    umount "$mnt"; rmdir "$mnt"
fi
echo "Done. Boot the computer from $dev to install TotV."
