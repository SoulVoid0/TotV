#!/usr/bin/env bash
# End-to-end test of the TotV installer ISO in QEMU:
#   1. boot the ISO (its kernel, with console=ttyS0 and archiso's script=)
#   2. the script runs `totv-install --answers` onto a blank virtual disk
#   3. boot the installed disk with BIOS (SeaBIOS) and with UEFI (OVMF) and
#      wait for its login prompt on the serial console
#
#   os/tests/vm-install.sh totv-<version>-x86_64.iso [workdir] [system-image-dir]
#
# With a system-image-dir (holding totv-system-*.iso.parts and its parts, or the whole
# .iso) it is put on a second virtual disk and the installer installs from the image;
# without one it installs from packages (SOURCE=packages: KDE, Wine and the game are
# downloaded, VOTV_URL permitting).
#
# Needs qemu-system-x86_64, qemu-img, bsdtar, python3, blkid, OVMF; uses KVM
# when /dev/kvm exists. Logs: <workdir>/{install,boot-bios,boot-uefi}.log
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

iso=$(realpath "$1")
work=$(realpath -m "${2:-./vm-test}")
imgdir=${3:+$(realpath "$3")}
mkdir -p "$work"
cd "$work"

accel=(-machine q35 -cpu max)
# shellcheck disable=SC2054
[[ -w /dev/kvm ]] && accel=(-machine q35,accel=kvm -cpu host)
mem=4G
user=totvtest
host=totv-test

label=$(blkid -o value -s LABEL "$iso")
echo "ISO label: $label"
bsdtar -xf "$iso" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img

cat >auto.sh <<EOF
#!/bin/bash
# Run by archiso's .automated_script.sh (script= on the kernel command line).
exec >/dev/ttyS0 2>&1
cat >/tmp/answers <<'ANS'
DISK=/dev/vda
HOSTNAME=$host
USERNAME=$user
USER_PASSWORD=test
ROOT_PASSWORD=
TIMEZONE=Europe/Berlin
LOCALE=en_US.UTF-8
KEYMAP=us
AUTOLOGIN=no
SOURCE=$([[ -n $imgdir ]] && echo image || echo packages)
CONFIRM_WIPE=yes
KERNEL_CMDLINE=console=ttyS0,115200
ANS
if totv-install --answers /tmp/answers; then
    echo TOTV-INSTALL-OK
    mount /dev/vda3 /mnt
    echo "--- /etc/totv/user.conf"; cat /mnt/etc/totv/user.conf
    echo "--- /etc/totv/totv.conf"; cat /mnt/etc/totv/totv.conf
    echo "--- os-release"; cat /mnt/etc/os-release
    echo "--- /"; ls -la /mnt
    echo "--- /users"; ls -la /mnt/users
    echo "--- groups"; arch-chroot /mnt id $user
    echo "--- lsiw"; arch-chroot /mnt runuser -u $user -- lsiw cdrive
    arch-chroot /mnt runuser -u $user -- lsiw path linux 'C:\\etc\\hosts'
    arch-chroot /mnt runuser -u $user -- lsiw path win /home/$user/x.txt
    echo "--- totv-config"; arch-chroot /mnt totv-config username
    echo "--- packages"; arch-chroot /mnt pacman -Q lsiw totv-base votv-os wine linux
    echo "--- /.VotV"; ls -la /mnt/.VotV /mnt/.VotV/r2modman
    echo "--- services"; arch-chroot /mnt systemctl is-enabled totvd.service totv-shell.service totv-update-check.timer
    echo "--- votv user"; arch-chroot /mnt id votv
    echo "--- update check"; arch-chroot /mnt totv-update --check || true
    umount /mnt
    echo TOTV-CHECKS-DONE
else
    echo TOTV-INSTALL-FAILED
    tail -n 80 /var/log/totv-install.log
fi
sync
systemctl poweroff
EOF

python3 -m http.server 8089 --bind 127.0.0.1 >http.log 2>&1 &
http=$!
trap 'kill $http 2>/dev/null || true' EXIT

rm -f disk.qcow2
qemu-img create -f qcow2 disk.qcow2 48G >/dev/null
extra=()
if [[ -n $imgdir ]]; then
    # The system image on a second disk (ext4, made without root by mkfs.ext4 -d).
    need=$(du -sm "$imgdir" | cut -f1)
    rm -f data.img
    mkfs.ext4 -q -L TOTV_DATA -d "$imgdir" data.img "$((need + 512))M"
    # shellcheck disable=SC2054
    extra=(-drive file=data.img,format=raw,if=virtio,readonly=on)
fi

echo "== Installing (log: $work/install.log)"
timeout 3600 qemu-system-x86_64 "${accel[@]}" -m "$mem" -smp 4 -display none -no-reboot \
    -serial "file:install.log" \
    -kernel arch/boot/x86_64/vmlinuz-linux -initrd arch/boot/x86_64/initramfs-linux.img \
    -append "archisobasedir=arch archisolabel=$label console=ttyS0,115200 script=http://10.0.2.2:8089/auto.sh" \
    -drive file="$iso",media=cdrom,readonly=on \
    -drive file=disk.qcow2,if=virtio,format=qcow2 "${extra[@]}" \
    -nic user,model=virtio-net-pci || true
sed -n '/TOTV-INSTALL-/,$p' install.log | tr -d '\r' | head -n 200
grep -q TOTV-INSTALL-OK install.log || { echo "FAIL: installation"; tail -n 60 install.log; exit 1; }
grep -q TOTV-CHECKS-DONE install.log || { echo "FAIL: checks after installation"; exit 1; }

# Boots the installed disk until "<host> login:" shows on the serial console.
boot() {
    local name=$1; shift
    echo "== Booting the installed disk: $name"
    rm -f "boot-$name.log"
    qemu-system-x86_64 "${accel[@]}" -m 2G -smp 2 -display none "$@" \
        -serial "file:boot-$name.log" \
        -drive file=disk.qcow2,if=virtio,format=qcow2,snapshot=on -nic none &
    local q=$! t
    for ((t = 0; t < 600; t += 5)); do
        if grep -q "$host login:" "boot-$name.log" 2>/dev/null; then
            kill "$q"; wait "$q" 2>/dev/null || true
            echo "OK: $name boot reached the login prompt"
            grep -a -m1 -E 'TotV|Welcome' "boot-$name.log" || true
            return 0
        fi
        kill -0 "$q" 2>/dev/null || break
        sleep 5
    done
    kill "$q" 2>/dev/null || true
    echo "FAIL: $name boot"; tail -n 40 "boot-$name.log"
    return 1
}

rc=0
boot bios || rc=1
first() { local f; for f; do [[ -f $f ]] && { echo "$f"; return 0; }; done; return 0; }
code=$(first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd)
vars=$(first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd)
if [[ -n $code && -n $vars ]]; then
    cp "$vars" vars.fd
    boot uefi -drive if=pflash,format=raw,readonly=on,file="$code" -drive if=pflash,format=raw,file=vars.fd || rc=1
else
    echo "SKIP: no OVMF firmware for the UEFI boot test"
fi
exit "$rc"
