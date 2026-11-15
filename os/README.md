# TotV OS

TotV is an operating system based on Arch Linux. This release has no desktop
yet: it boots to a console. It comes with
[LSIW](https://github.com/SoulVoid0/LSIW), and on TotV **the C: drive is the
Linux root**: `C:\etc\hosts` is `/etc/hosts`, `C:\home\<you>` is
`/home/<you>`, and the folders Windows programs expect are real folders at
the top of the file system (`/windows`, `/Program Files`,
`/Program Files (x86)`, `/ProgramData`, `/users`).

## Install

1. Get the ISO: the **Build TotV OS** workflow's `totv-iso` artifact, or a
   release (`totv-<version>-x86_64.iso`).
2. Write it to a USB stick: `sudo tools/write-usb.sh totv-*.iso /dev/sdX` on
   Linux (it refuses non-removable disks), or balenaEtcher / Rufus in DD mode.
3. Boot a computer from the stick. The installer starts by itself on the
   first console and asks for:
   * the disk to install on: an internal disk or **another USB stick**
     (everything on it is erased; the installer stick itself is not offered),
   * your **username** (also the name of your Voices of the Void save) and
     password, an optional root password (empty locks root; you use sudo),
   * computer name, time zone, language, keyboard,
   * options: Wine (LSIW's fallback engine) and autologin (on by default),
   * if an extension needs it, where your copy of Voices of the Void is.
4. Remove the installer stick and reboot.

The default ISO holds every package, so no network is needed to install.
`totv-install --answers FILE` installs unattended (`totv-install --help`).

The installed disk boots on BIOS and UEFI computers, and keeps every driver
in its initramfs, so a TotV USB stick boots on other computers too.

## Layout of an installed system

| What | Where |
|---|---|
| Installer choices | `/etc/totv/totv.conf` (`TOTV_VERSION`, `HOSTNAME`, `AUTOLOGIN`, `OPTIONS`, `OFFLINE`, `TOTV_INSTALL_DATE`) |
| The user | `/etc/totv/user.conf`: `USERNAME=<name>`, `SAVE_NAME=<name>` |
| Reading them | `totv-config username`, `totv-config get KEY`, `totv-config show`, or `. /etc/totv/user.conf` |
| LSIW configuration | `/etc/lsiw/lsiw.conf` (`c_drive = /`, Windows folders) |
| Windows folders | `/windows`, `/Program Files`, `/Program Files (x86)`, `/ProgramData`, `/users` (group `cdrive`, setgid, group-writable); `/users/<name>` → `/home/<name>` |
| Session hooks | `/usr/lib/totv/session.d/*.sh`, `/etc/totv/session.d/*.sh` |
| Disk | GPT: 1 MiB BIOS boot, 1 GiB ESP (`TOTV_EFI`, at `/boot`), ext4 root (`TOTV_ROOT`) |
| Packages | Arch `core`/`extra`/`multilib` plus `[totv]` (`https://github.com/SoulVoid0/TotV/releases/latest/download`) |

The user is in `wheel` (sudo) and `cdrive`.

### Session hooks

With autologin the user is logged in on tty1. A login shell there sources
every `*.sh` of `/usr/lib/totv/session.d` and `/etc/totv/session.d` in name
order (a file in `/etc` replaces the one of the same name in `/usr/lib`; an
empty one disables it). A hook can `exec` a session, e.g.
`exec votv-os-session`. `TOTV_NO_SESSION=1` skips them.

### Extensions (installer hooks)

`build.sh` copies `votv/host/` (and `os/extensions/<name>/`), when it has an
`install.sh`, into the ISO as `/opt/totv/hooks/<name>/`. After the base
system is installed and the user exists, the installer runs
`install.sh /mnt` with:

| Variable | Value |
|---|---|
| `TOTV_ROOT` | `/mnt` (the new system) |
| `TOTV_USERNAME` | the username |
| `TOTV_OFFLINE` | `1` if installing from the ISO's own repository |
| `TOTV_GAME_ARCHIVE` | the Voices of the Void archive or folder the user picked, or empty |
| `TOTV_OPTIONS` | the chosen options (e.g. `wine`) |

While hooks run, the new system's pacman uses the installer's sources, so
`arch-chroot "$TOTV_ROOT" pacman -S --needed --noconfirm <pkgs>` works
offline for every package listed in the extension's `packages.x86_64` (one
per line; `build.sh` bundles them with their dependencies).

## LSIW with C: = /

`totv-base` ships `/etc/lsiw/lsiw.conf` with `c_drive = /` and the Windows
folders at the root. The `lsiw` package carries one patch
(`packages/lsiw/0001-cdrive-at-linux-root.patch`): when C: is `/`, `lsiw sync`
does not link top-level directories into C: (they already are there; as root
it would otherwise replace `/bin`, `/lib`, ... with links to themselves), and
`lsiw cdrive set/reset` refuses to move the drive.

## Build

On Arch Linux (or in `archlinux:latest` with `--privileged`), as root:

```sh
pacman -S --needed archiso base-devel git
os/build.sh            # out/totv-<version>-x86_64.iso, out/SHA256SUMS, out/repo/
os/build.sh --online   # smaller ISO; packages are downloaded at install time
```

CI (`.github/workflows/build-os.yml`) does this on every change to `os/`;
a `v*` tag publishes the ISO and the `[totv]` package repository as a
release.

| Path | Contents |
|---|---|
| `packages/lsiw/` | PKGBUILD for LSIW 1.11.0 (+ the C: = / patch), split `lsiw` / `lsiw-control` |
| `packages/totv-base/` | TotV's configuration package |
| `target-packages.x86_64` | packages of the installed system |
| `optional-packages.x86_64` | installer options |
| `iso/` | additions to archiso's `releng` profile: the installer (`airootfs/usr/local/bin/totv-install`), live packages |
| `build.sh` | builds everything |
