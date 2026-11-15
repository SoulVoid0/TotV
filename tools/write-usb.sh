#!/usr/bin/env bash
# Writes the TotV installer ISO to a USB stick (Linux).
#
#   sudo tools/write-usb.sh totv-0.1.0-x86_64.iso            lists USB disks
#   sudo tools/write-usb.sh totv-0.1.0-x86_64.iso /dev/sdX   writes it
#
# On Windows or macOS use balenaEtcher or Rufus (DD mode) instead.
# SPDX-License-Identifier: MIT
set -euo pipefail

iso=${1:-}
dev=${2:-}
[[ -f $iso ]] || { sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 2; }

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
echo "Done. Boot the computer from $dev to install TotV."
