# TotV OS

TotV is an operating system based on Arch Linux. It boots into Voices of the Void:
the game is a core part of the system, stored in `/.VotV/<version>/`, and the in-game
PC is the KDE Plasma desktop of whoever is logged in. It comes with
[LSIW](https://github.com/SoulVoid0/LSIW), and on TotV **the C: drive is the Linux
root**: `C:\etc\hosts` is `/etc/hosts`, `C:\home\<you>` is `/home/<you>`, and the
folders Windows programs expect are real folders at the top of the file system
(`/windows`, `/Program Files`, `/Program Files (x86)`, `/ProgramData`, `/users`).
Wine is always installed (LSIW runs the game with it, or with GE-Proton).

## What starts when

1. **Boot**: `totv-shell.service` starts the TotV shell on the screens (KWin, as the
   `votv` system user) and Voices of the Void in the shared **Home** save `default`.
   There is no main menu. The in-game PC shows the login screen.
2. **Log in** on the in-game PC (the user created in the installer, or anyone added with
   `sudo totv-adduser NAME`): the game saves `default` and moves you to **your own save,
   named after your username** (a Home save, created the first time); the in-game PC is
   now your KDE Plasma desktop.
3. **Log out** (the *Log out* icon): back to `default`.

With *autologin* (installer option) step 2 happens by itself once `default` has loaded.

## Install

1. Get the installer, `totv-<version>-x86_64.iso` (a release, or the **Build TotV OS**
   workflow's `totv-iso` artifact). It is under 2 GiB.
2. Write it to a USB stick: `sudo tools/write-usb.sh totv-*.iso /dev/sdX` (Linux; it
   refuses non-removable disks), or balenaEtcher / Rufus in DD mode.
   `sudo tools/write-usb.sh totv-*.iso /dev/sdX --system DIR` also puts the system image
   (from `DIR`) on a `TOTV_DATA` partition of the same stick: then no network is needed.
3. Boot from the stick. The installer asks for the disk (an internal disk or **another
   USB stick**, at least 32 GiB; the installer stick is not offered), your **username**
   (your login and your save's name) and password, an optional root password,
   computer name, time zone, language, keyboard, and autologin.
4. It installs **the system image**: found on any drive (`totv-system-*.iso`, or its
   `.partNN` files with the `.parts` index), or downloaded from the release of its
   version. The parts are checked (SHA-256), merged on the target disk, checked again
   and unpacked. Without an image and with a network it installs from packages instead.
5. Remove the stick and reboot.

`totv-install --answers FILE` installs unattended (`totv-install --help`).
The installed disk boots on BIOS and UEFI computers and keeps every driver in its
initramfs, so a TotV USB stick boots on other computers too.

## Updates: no reinstall

`totv-update` (or the **TotV Update** app, or `sudo totv-update` in a terminal) updates
in place:

* every package with pacman: Arch Linux and TotV's `[totv]` repository
  (`https://github.com/SoulVoid0/TotV/releases/latest/download`: `lsiw`, `totv-base`,
  `votv-os` with the TotVOS mod), published by each release;
* the hooks in `/usr/lib/totv/update.d`: r2modman, and Voices of the Void itself when
  `"game": {"follow_latest": true}` is set in `/etc/totv/votv.json` (off by default:
  the TotVOS mod targets 0.9.0n). A new game build goes to `/.VotV/<new version>/` and
  `/.VotV/current` points to it; the old one stays until
  `sudo votv-os-install-game --prune`.

`totv-update-check.timer` checks once a day; the game restarts by itself when its mod or
build changed. `totv-update --check` exits 100 when there is something to update.

## Layout of an installed system

| What | Where |
|---|---|
| Voices of the Void | `/.VotV/<version>/` (`/.VotV/current` is the one that runs), owner `votv` |
| Saves (all users) | `/.VotV/saves/games/` (the game's SaveGames), `/.VotV/saves/registry.json` (title, mode, owner of each) |
| r2modman and the mods | `/.VotV/r2modman/` (`app/`, `r2modmanPlus-local/VotV/profiles/Default/`) |
| Calibration | `/.VotV/config/<user>.json` |
| The game's system user | `votv` (home `/var/lib/votv`; LSIW prefix there; `C:\users\votv`) |
| Installer choices | `/etc/totv/totv.conf`, `/etc/totv/user.conf` (`totv-config`) |
| VotV settings | `/etc/totv/votv.json` |
| LSIW configuration | `/etc/lsiw/lsiw.conf` (`c_drive = /`, Windows folders), `/var/lib/votv/.config/lsiw/lsiw.conf` (the game's) |
| Windows folders | `/windows`, `/Program Files`, `/Program Files (x86)`, `/ProgramData`, `/users` (group `cdrive`); `/users/<name>` → `/home/<name>` |
| Services | `totvd` (root: logins, r2modman, updates), `totv-shell` (tty1), `totv-desktop@<user>`, `totv-r2modman@<user>`, `totv-update(-check)`, all in `totv-core.slice` where they are the game's |
| Disk | GPT: 1 MiB BIOS boot, 1 GiB ESP (`TOTV_EFI`, at `/boot`), ext4 root (`TOTV_ROOT`) |

Users are in `wheel` (sudo, updates), `cdrive` and `votv`.

**Voices of the Void and r2modman are system processes**: they run as the `votv`
system user in `totv-core.slice`, so System Monitor lists them under *System
Processes* (not *Applications*), and a normal user cannot end them.

## LSIW with C: = /

`totv-base` ships `/etc/lsiw/lsiw.conf` with `c_drive = /`, the Windows folders at the
root and LSIW's own update check off (LSIW updates with the system). The `lsiw` package
carries one patch (`packages/lsiw/0001-cdrive-at-linux-root.patch`): when C: is `/`,
`lsiw sync` does not link top-level directories into C: (they already are there; as root
it would otherwise replace `/bin`, `/lib`, ... with links to themselves), and
`lsiw cdrive set/reset` refuses to move the drive.

The game runs as `votv`, whose own LSIW file sets `[steam] full_c_drive = false`: its
Proton prefix keeps a C: of its own, so Proton's `C:\users\steamuser` is never
`/users/steamuser` (which is the installed user's home, for that user's own Proton
programs). The game reaches the system through `Z:\` (= `/` in every Wine and Proton
prefix).

## Build

On Arch Linux (or in `archlinux:latest` with `--privileged`), as root:

```sh
pacman -S --needed archiso base-devel git arch-install-scripts squashfs-tools libisoburn
os/build.sh                                  # out/totv-<version>-x86_64.iso (< 2 GiB), out/repo/
os/system/build-system.sh --repo out/repo    # out/totv-system-<version>-x86_64.iso + .partNN + .parts
```

`build-system.sh` downloads Voices of the Void (`votv-os-game`: itch.io, or `VOTV_URL`
/ `ITCH_API_KEY`; `--game ZIP` uses a file you have, `--no-game` leaves it out),
GE-Proton, shimloader and r2modman. CI (`.github/workflows/build-os.yml`) builds all
three, installs the system image in a VM (BIOS and UEFI boot), and on a `v<version>`
tag (the `totv-base` version, e.g. `v0.2.0`) publishes the installer, the system image
parts and the repository as a release.

| Path | Contents |
|---|---|
| `packages/lsiw/` | LSIW 1.11.0 (+ the C: = / patch), split `lsiw` / `lsiw-control` |
| `packages/totv-base/` | the OS configuration, `totv-update`, `totv-adduser`, `totv-config` |
| `packages/votv-os/` | the Voices of the Void part (from `../votv`) |
| `target-packages.x86_64` | the base packages of the installed system |
| `iso/` | the installer live system: `airootfs/usr/local/bin/totv-install` |
| `system/build-system.sh` | the system image |
| `tests/vm-install.sh` | the VM test |
