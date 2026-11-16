# TotV

TotV is an operating system based on Arch Linux that lives inside
**Voices of the Void**: it boots into the game, the in-game PC is your KDE Plasma
desktop, and LSIW (with the C: drive at `/`) runs the game with Wine or Proton.

* [`os/`](os/README.md): the OS: packages, the USB installer, the system image, updates.
* [`votv/`](votv/README.md): the Voices of the Void part: the TotVOS mod (shimloader),
  the Home game mode, the shell, the apps (VotV Saves, VotV Mods, VotV PC, ...).
* [`tools/write-usb.sh`](tools/write-usb.sh): write the installer to a USB stick (and,
  optionally, the system image next to it).

## Downloads (each release)

| File | What |
|---|---|
| `totv-<version>-x86_64.iso` | the **installer** (under 2 GiB): write it to a USB stick |
| `totv-system-<version>-x86_64.iso.part00`, `.part01`, ... and `.parts` | the **system image** (the whole OS with the game and r2modman, over 2 GiB), in parts; the installer downloads and merges them itself, or finds them on a drive |
| `totv.db`, `*.pkg.tar.zst` | the `[totv]` package repository: installed systems update from it (`totv-update`) |

Install: write the installer to a USB stick, boot it, answer the questions. See
[os/README.md](os/README.md).
