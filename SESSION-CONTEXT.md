# TotV: context for a new Claude session

Give this file to a new session first. It summarises what the user asked for, what is
built, where everything is, what was learned while researching, and what is still open.
Repository: `SoulVoid0/TotV` (GitHub). Work happens on a `claude/...` branch, and the
user has asked for everything to be on `main` as well (fast-forward pushes to `main`
were done with their permission).

---

## 1. What the user wants (all requests so far, in order)

**Session 1 (the original prompt):**
1. An OS based on Arch Linux, no desktop at first, with **LSIW** (github.com/SoulVoid0/LSIW)
   integrated so that **the C: drive is `/`**.
2. An **installer OS for USB** that lets the user set the OS up and install it (onto a disk
   or another USB stick).
3. A **mod for Voices of the Void (VotV) 0.9.0n**, only dependency **shimloader**, that:
   - makes the in-game PC a **KDE Plasma desktop, which is the OS desktop**;
   - boots the OS **straight into a save named after the username chosen in the installer**;
   - with **2+ monitors** the inventory shows on another monitor (1 monitor: normal);
   - a KDE app that **relays the game's own PC** (all of its functions), because the in-game
     PC is replaced by the KDE desktop;
   - **performance improvements that change nothing visible**;
   - when the player uses the in-game PC the in-game screen stays visible as in the base
     game, but its position is **calibrated by the player to line up with the real screens**.

**Session 2 (the current requests):**
1. Put the main OS on `main`. Install the mod together with VotV, and set up **r2modman for
   VotV** by default, all inside the main OS.
2. An **installer ISO that must stay under 2 GB** (GitHub's limit for release files), plus an
   **ISO of the main OS that may be bigger**: the installer **merges** it correctly (it is
   released in parts).
3. **Update the OS without reinstalling** when a new release comes out.
4. VotV is stored in **`/.VotV/[game version]/`** and is a **core part of the OS**. All changes
   to VotV and how it works go through the mod.
5. A new VotV game mode, **Home**: the game **clock follows real life**, the player **never gets
   hungry or tired**, and the **power never goes out, even from events**.
6. Home mode has a save named **`default`**, **shared by all users**, which is **the first thing
   you see when the OS boots**. When a user **logs in** with their account they are **moved to
   the save named after their username**.
7. A **Plasma app to create, modify and load saves** (like the base game's menu). Loading a
   save moves you from Home into it.
8. **The game's normal main menu no longer exists.**
9. A folder **`/.VotV/r2modman`** holds r2modman and all the mods.
10. **r2modman and VotV must count as system resources in the task manager** (they are
    essential to the system).

**Added while session 2 was running:**
- **Wine MUST be installed by default** in LSIW, otherwise the game will not start.
- r2modman won't install mods while the game runs, so: a **separate app that downloads and
  installs mods into the right place**, plus an **"Apply mods" button that restarts the OS**
  so new or removed mods take effect.
- r2modman does not need to be running to launch with its profile. The user showed r2modman's
  "launch from outside the mod manager" argument:
  `--mod-dir <profile>\shimloader\mod --pak-dir ...\pak --cfg-dir ...\cfg --overlay-dir ...\overlay`.
  Use that so the OS runs better: r2modman stays closed while playing.
- **LSIW must be fully integrated with no weird bugs.**
- "You haven't released yet": the user expects a **GitHub Release** with the downloads.

User preferences: be efficient, no human-like chatter, be thorough, research as much as
needed to fully deliver.

---

## 2. What exists now (all on `main`)

### Top level
```
README.md                     overview + the release downloads table
SESSION-CONTEXT.md            this file
.github/workflows/build-os.yml  builds packages, the installer ISO, the system image, a VM test, the release
.github/workflows/votv.yml      mod tests (Lua mock), host tests (PyQt6), lint (shellcheck, pyflakes), Thunderstore zip
tools/write-usb.sh            writes the installer to USB; --system DIR adds a TOTV_DATA exFAT partition with the image parts
os/                           the OS
votv/                         the VotV part (mod + host side)
```

### `os/`
| Path | What |
|---|---|
| `packages/lsiw/` | PKGBUILD for LSIW 1.11.0 + `0001-cdrive-at-linux-root.patch` (C: = `/`: `lsiw sync` does not link top-level dirs; `lsiw cdrive set/reset` refuses) |
| `packages/totv-base/` (pkgver **0.2.0**) | `/etc/lsiw/lsiw.conf` (`c_drive = /`, Windows folders `/windows`, `/Program Files`, `/Program Files (x86)`, `/ProgramData`, `/users`; `[update] check = false`), sysusers (group `cdrive`), tmpfiles, os-release branding, sudoers, portable mkinitcpio, `totv-config`, **`totv-update`**, **`totv-adduser`**, `/usr/lib/totv/update.d/` |
| `packages/votv-os/` | pacman package of `votv/` (`build.sh` copies `votv/` next to the PKGBUILD). Depends on everything in `votv/host/packages.x86_64` + totv-base + lsiw. Its build() downloads shimloader. post_upgrade touches `/run/totv/votv-os/mod-updated` |
| `build.sh` | builds lsiw, totv-base, votv-os with makepkg, makes the `[totv]` repository, builds the **installer ISO** (archiso releng + `iso/`), **fails if it is ≥ 2 GiB**. Default: the ISO holds only TotV's own packages; `--offline` also bundles the base packages (that ISO is over 2 GiB) |
| `system/build-system.sh` | the **system image**: pacstrap of target + votv packages + votv-os, then runs `/usr/share/votv-os/host/install.sh /` in a chroot (downloads the game, GE-Proton, shimloader, r2modman), makes it generic (machine-id, keyring, initramfs removed), squashfs (zstd) inside an ISO 9660 (iso-level 3), split into **1900 MiB parts** `totv-system-<ver>-x86_64.iso.partNN` + index `…iso.parts` (lines `image SIZE SHA256 NAME` / `part SIZE SHA256 NAME`). Options `--repo DIR` (required), `--game ZIP`, `--no-game` |
| `iso/airootfs/usr/local/bin/totv-install` | the installer (dialog UI or `--answers FILE`). Sources: **image** (finds the `.iso` or `.parts` on any drive, including the TOTV_DATA partition; otherwise downloads the parts from `releases/download/v<ver>` then `releases/latest/download`; checks each part, merges them on the target, checks the whole image, loop-mounts it, unsquashfs, then `pacman-key --init/--populate`, `systemd-machine-id-setup`) or the **packages** fallback (pacstrap + `install.sh` with `VOTV_FETCH=1`). GPT: BIOS boot + 1 GiB ESP + ext4 root; GRUB BIOS + UEFI `--removable`. Min disk 32 GiB. Answer keys: DISK HOSTNAME USERNAME USER_PASSWORD ROOT_PASSWORD TIMEZONE LOCALE KEYMAP AUTOLOGIN SOURCE IMAGE IMAGE_URL GAME_ARCHIVE CONFIRM_WIPE REBOOT KERNEL_CMDLINE. Writes `/etc/totv/totv.conf` and `/etc/totv/user.conf` (USERNAME, SAVE_NAME). The user goes into groups wheel, cdrive, votv, gamemode |
| `target-packages.x86_64` | base packages (now includes wine, pacman-contrib, squashfs-tools) |
| `optional-packages.x86_64` | empty (Wine is no longer optional) |
| `iso/packages.x86_64` | live installer extras (dialog, gptfdisk, squashfs-tools, exfatprogs, ntfs-3g, curl, ...) |
| `tests/vm-install.sh ISO [workdir] [system-image-dir]` | QEMU: installs unattended (the image goes on a second ext4 disk made with `mkfs.ext4 -d`), checks, boots BIOS and UEFI |

### `votv/mod/` (TotVOS 2.0.0, UE4SS Lua, `TotVOS/Scripts/`)
- `main.lua`: 50 ms loop on the game thread. PC tick every 100 ms, Home fast tick every 200 ms, slow tick every 1 s (config reload, screens, saves, Home, perf).
- `saves.lua`: **no main menu.** Reads `target.json` (`{seq,name,title,mode,base_mode,create,rules}`) from the runtime dir and converges on it. Hides the menu widgets (`ui_mainMenu_C`, `ui_saveSlots_C`, ...) and fades the camera to black, but **only when a target exists** (without TotV OS the game is untouched). Learns slot prefixes from `ui_saveSlots_C:getSavePrefix(0..7)` and stores them in `Z:\.VotV\saves\prefixes.json`. Loads like the game's menu: `LoadGameFromSlot` / `CreateSaveGameObject(saveSlot_C)` + copy `gameRules` + apply rule overrides, `gi:setSaveSlotObject(save, slot)`, `loadObjects`, `GameMode`, `startDay = savedtime.Z`, `open untitled_1`. Before a switch it calls the first `saveGame/saveAll/saveWorld/save` it finds on `mainGamemode_C`. If the game falls back to its menu it loads the target again. Emits `save_loading`, `save_loaded`, `save_switching`, `in_game`.
- `home.lua`: **Home rules** while the running save's mode is `home`:
  - **Clock:** `daynightCycle_C.day` (0..MaxTime is one day) is set to local real time. Calibrated once from `timeZ` (X = hour, Y = minute). Sets `realtime = true` and trims `TimeScale` toward real-time pace.
  - **Needs:** `gi.save_gameInst.food/sleep` stay at 100; the pawn's `foodDraining/sleepDraining` stay at 0.
  - **Power:** if `powerControl_C.disabled` is true it sets false, restores the breakers (`press_coord/downl/play/calc/light`), calls `buttonsVisibility()`, `servers[].setActive(true)` and `playSND(true)`. Broken `generator_C` (`isBroken`) get `fullFix()`. Post-hooks are registered via `RegisterHook` on `powerControl_C:solar` (the blackout) and `virus_pb` (the lockout), found through `ForEachFunction` + `GetFullName`.
- `pcscreen.lua` (KDE frames as a texture on every `ui_laptop_C`, camera alignment), `relay.lua` (VotV PC relay + second-screen inventory), `widgetmirror.lua`, `perf.lua`, `ipc.lua`, `config.lua`, `util.lua`, `json.lua`: carried over from session 1.
- **Paths for the game use `Z:\`** (= `/` in every Wine and Proton prefix). Defaults: runtime `Z:\run\totv\votv-os`, system config `Z:\etc\totv\votv.json`, user config `Z:\.VotV\config\<user>.json` (the user comes from `session.json`), saves `Z:\.VotV\saves`.
- `manifest.json` / `package.sh`: Thunderstore zip `TotV-TotVOS-2.0.0.zip`, with the mod in `mod/`.

### `votv/host/` (Linux side, packaged as votv-os)
**Architecture.** The game, the shell compositor and r2modman run as the **system user `votv`**
(home `/var/lib/votv`, nologin, in `totv-core.slice`). That is the "system resource" answer:
System Monitor lists them under *System Processes*, and normal users cannot kill them.

- **`systemd/`**
  - `totv-shell.service`: User=votv, PAMName=login, tty1, `display-manager` alias, conflicts with getty@tty1. Runs `votv-os-session`: `kwin_wayland` on DRM with the Wayland socket **`/run/totv/shell/wayland-0`**, mode 0660, group votv. The socket is created by `votv-wayland-socket` and passed with `--wayland-fd` because XDG_RUNTIME_DIR is 0700.
  - `totvd.service`: the root helper, socket `/run/totv/totvd.sock` (group votv, SO_PEERCRED). Ops: `login` (PAM service `totv-login`, from votv only), `autologin`, `logout`, `ended`, `r2modman`, `restart-game`, `apply-mods` (sends `save_now`, then `systemctl reboot` after 4 s), `update`, `update-status`, `status`. Writes `/run/totv/votv-os/session.json`.
  - `totv-desktop@<user>.service`: User=%i, PAMName=totv-desktop. Runs `votv-pc-session`: a nested kwin_wayland (a client of the shell) with Plasma and its own dbus-run-session; its own socket is `/run/totv/pc/<user>/wayland-0` (group votv) so r2modman can show there. `ExecStopPost=totvd --ended`.
  - `totv-r2modman@<user>.service`: User=votv, UMask=0002, `WAYLAND_DISPLAY=/run/totv/pc/%i/wayland-0`. Runs `votv-os-r2modman run` (`XDG_CONFIG_HOME=/.VotV/r2modman`, so r2modman's data is `/.VotV/r2modman/r2modmanPlus-local`).
  - `totv-update.service` (`totv-update --yes`, log `/var/log/totv-update.log`), `totv-update-check.{service,timer}` (daily), `totv-core.slice`.
- **`bin/`**
  - `votv-os-session-main` (inside the shell): reset IPC, clear `profiles/*/totv-pending.json`, start the bridge, `votv-login` (greeter) and `votv-inventory`, then keep the game running (restart on crash or on `/run/totv/votv-os/restart-game`; after 3 crashes in 2 minutes, a dialog).
  - `votv-os-launch-game`: game in `/.VotV/current`; r2modman profile `…/VotV/profiles/<mods.profile>`; symlink `shimloader/mod/TotV-TotVOS -> /usr/lib/votv-os/mods/TotVOS`; SaveGames symlink → `/.VotV/saves/games` for both the Wine LOCALAPPDATA and the Proton prefix steamuser; Engine.ini tweaks; env (`WINEDLLOVERRIDES=dwmapi=n,b`, fsync, DXVK cache, `LSIW_NO_IDENTITY=1`, `WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER=1`); `lsiw run -e <engine>` (auto: proton if `lsiw runners` lists one, else wine) with `--mod-dir/--pak-dir/--cfg-dir/--overlay-dir` = the profile's shimloader dirs (Z:\ paths).
  - `votv-os-game`: status / latest / fetch / install / update [--check] from itch.io (`mrdrnose.itch.io/votv`: the page flow `download_url` → upload ids → `file/<id>`; or `ITCH_API_KEY`; or `VOTV_URL`).
  - `votv-os-install-game`: puts a build in `/.VotV/<version>`, sets the `current` symlink, copies shimloader (`dwmapi.dll`, `UE4SS.dll`, settings with consoles off), owner votv; `--shimloader-only`, `--prune`.
  - `votv-os-r2modman`: install (latest GitHub release AppImage, extracted; unsquashfs fallback) / seed (profile Default, shimloader dirs, `mods.yml` with Thunderstore-unreal_shimloader + TotV-TotVOS, `launch/VotV.exe` script = `votv-os-ctl restart-game`, group-writable setgid) / update [--check] / run.
  - `votv-os-fetch-deps` (shimloader 1.1.7 from Thunderstore, GitHub fallback), `votv-wayland-socket`, `votv-pc-session`, `votv-pc-desktop` (Plasma + `votv-pc-agent`), `votv-os-engine-ini`.
- **`lib/votvos/` (Python, PyQt6)**
  - `paths.py`: all locations.
  - `config.py`: defaults; `effective(user)`.
  - `ipc.py`: JSONL IPC.
  - `saves.py`: `Registry`. `/.VotV/saves/registry.json` holds name → title, mode, owner (`*` = shared), rules, base_mode, slot, last_played. `default` is shared; `<user>` is the user's own (can't be renamed or deleted); created saves are `<user>-<title>`. Also create/rename/duplicate/delete (to `deleted/`)/load (writes `target.json`).
  - `bridge.py`: the votv-side daemon: screens.json, follows `session.json` → target (`default` or the user's save), `bridge-state.json`, D-Bus `org.totv.VotvOS` WindowState/LeavePC/Status for the KWin script; triggers autologin after `default` loads when `AUTOLOGIN=yes`.
  - `totvd.py`: the root helper, with PAM via ctypes.
  - `desktop.py`: apps: `votv-login` (greeter; draws its own frames), `votv-pc-agent` (KWin ScreenShot2 capture → frames), **VotV Saves** (`votv-saves`, also a CLI), **VotV Mods** (`votv-mods`), `votv-logout`, **TotV Update** (`totv-updater`), `votv-os-ctl`.
  - `mods.py`: Thunderstore index `thunderstore.io/c/voices-of-the-void/api/v1/package/`, dependency planning, install into r2modman layout (`shimloader/mod|pak|overlay/<Owner-Name>/…`, `cfg/` untracked, top-level `.pak` → pak), writes `mods.yml`, uninstall with a dependency check, `totv-pending.json`. Built-ins Thunderstore-unreal_shimloader and TotV-TotVOS are protected.
  - `capture.py` (NestedCapture + FrameWriter), `apps.py` (VotV PC relay, VotV Inventory, VotV Screen Setup), `mirrorview.py`.
- `kwin/votv-os-wm/`: KWin 6 script: the game fullscreen on the primary screen; the PC (greeter or user desktop) fullscreen while in use, otherwise minimized (the other PC window always minimized); inventory on the 2nd screen; Meta+Esc leaves the PC.
- `config/`: `votv.json` (system defaults), `sysusers.conf` (user votv + groups), `tmpfiles.conf` (`/.VotV` dirs, `/run/totv/*`, `L /users/votv -> /var/lib/votv`), pipewire-pulse drop-in (shell audio at `/run/totv/shell/pulse/native`; desktops use `PULSE_SERVER`), `dxvk.conf`.
- `pam/totv-login`, `pam/totv-desktop`; `share/applications/*.desktop` (desktop icons via /etc/skel/Desktop: VotV PC, VotV Saves, VotV Mods, r2modman, Screen Setup, TotV Update, Restart VotV, Log out).
- `update.d/50-votv`: the totv-update hook (r2modman update + seed, the game only if `game.follow_latest`, shimloader, restart the game after a mod update).
- `install.sh`: `--files-only DESTDIR` (used by the package), or a full setup of a root. The setup does: sysusers/tmpfiles, enable services, graphical target, users → votv group, votv's `~/.config/lsiw/lsiw.conf` (`wine = auto`, `[steam] full_c_drive = false`, no update check), `/users/votv` link, GE-Proton (`lsiw runners install ge`), shimloader, the game (`TOTV_GAME_ARCHIVE` or `VOTV_FETCH=1`), r2modman install + seed. Env: `VOTV_SKIP_PACKAGES`, `TOTV_OFFLINE`, `TOTV_USERNAME`.
- `packages.x86_64`: KDE (kwin, plasma-*), Python/PyQt6, pipewire, gamemode, Vulkan (+ lib32), **wine, wine-mono, wine-gecko, winetricks**, python-yaml, squashfs-tools, curl, plasma-systemmonitor, 7zip, unzip.

### Boot and login flow
Boot → `totv-shell` (votv) → bridge writes `target.json` = `default` (Home) → the mod hides the
menu and loads `default` → the in-game PC shows `votv-login` → the user logs in → totvd (PAM)
starts `totv-desktop@user` and writes `session.json` → the bridge targets the save `<user>`
(mode `saves.user_mode`, default `home`) → the mod saves `default` and switches → the in-game PC
is the user's Plasma. Log out → back to `default`. Autologin (an installer option, default off)
logs in once `default` has loaded.

### Updates
`totv-update [--check|--yes]`: keyring, `pacman -Syu` (installed systems have
`[totv] Server = https://github.com/SoulVoid0/TotV/releases/latest/download`), then the
`update.d` hooks. `--check` uses `checkupdates` and exits 100 when updates exist.

---

## 3. Research facts (verified sources)

- **VotV internals (from github.com/VOTV-MP/Multivoid, `src/votv-coop/src/ue_wrap/...`):**
  - Stats are on `mainGameInstance_C.save_gameInst` (`saveSlot_C`): `food`, `sleep`, `health`, ... floats. On the pawn: `foodDraining`, `sleepDraining`, `isExhausted_bool`.
  - Clock: `daynightCycle_C` with `totalTime`, `Day`, `TimeScale`, `MaxTime` (one day), `timeZ` (FIntVector hour, minute, day), `realtime` (bool), `diff_mult`, `sleepingTimeDilation`.
  - `mainGamemode_C.isMainMenu`.
  - Game modes (enum order): Story 0, Infinite 1, Tutorial 2, Custom 3, Sandbox 4, Halloween 5, Ambient 6, Solar 7. Custom and Tutorial have no slot prefix.
  - Power: `mainGamemode_C.powerControl` (`powerControl_C`: `disabled`, `waterlogged`, `press_coord/downl/play/calc/light`, `buttonsVisibility()`, `playSND(activated)`, `solar()` = blackout, `virus_pb` = lockout, `servers` array with `setActive`); `mainGamemode_C.powerUsage`; `generator_C` (`isBroken`, `break`, `fullFix`, `upgradeLevel`).
  - Saves: `GameplayStatics.SaveGameToSlot/LoadGameFromSlot/DoesSaveGameExist`, `ui_saveSlots_C.getSavePrefix`, `processSaveNameIntoSubsave`, map `untitled_1`, menu map `/Game/menu`.
  - **Not found:** the name of the gamemode's own "save world" function (saves.lua guesses).
- **r2modman (github.com/ebkr/r2modmanPlus, `src/assets/data/ecosystem.json`):**
  - VotV: `internalFolderName: VotV`, `exeNames: [VotV.exe]`, `packageLoader: shimloader`, platform `other`.
  - Install routes: `shimloader/mod` (default, subdir tracking), `shimloader/pak` (subdir), `shimloader/cfg` (no tracking), `shimloader/overlay` (subdir).
  - Launch args: `--mod-dir <profile>/shimloader/mod --pak-dir … --cfg-dir … --overlay-dir …`.
  - Data folder: Electron `appData` (= `$XDG_CONFIG_HOME` on Linux) + `r2modmanPlus-local`. Profiles: `<root>/VotV/profiles/<name>/`, with `mods.yml` (a list of ManifestV2 objects).
  - "Start modded" on Linux runs `"VotV.exe" args` in the configured game folder. The game folder is stored in r2modman's IndexedDB, so it can't be preset: the user picks `/.VotV/r2modman/launch` once.
- **LSIW (README):** `lsiw run -e wine|proton|proton:VER|wine:VER`, `lsiw runners install ge`, `lsiw config get --linux VAR`, `lsiw path linux|win`. `/etc/lsiw/lsiw.conf` + `~/.config/lsiw/lsiw.conf`; `[steam] full_c_drive` (default true, maps Proton's C: to the whole FS); `[update] check`. `LSIW_NO_IDENTITY=1` turns off the per-app scope (otherwise the game would show under Applications). `C:\users\<me>` and `C:\users\steamuser` both = USERPROFILE (the home).
- **Game download:** itch.io `mrdrnose.itch.io/votv`, name-your-own-price, 0.9.0n zip ≈ 2.1 GB. Redistributing it inside the system image is a licensing question the user has been told about.
- **shimloader:** Thunderstore `Thunderstore/unreal_shimloader` 1.1.7 (`dwmapi.dll` + `UE4SS.dll` + `UE4SS-settings.ini`).

---

## 4. Current state / open items

- **Release:** none yet. This sandbox **cannot push git tags** (the proxy rejects them), so the
  workflow's `release` job now publishes **`v<totv-base pkgver>` (v0.2.0)** after every
  successful build of `main` (softprops/action-gh-release with `tag_name`, `make_latest`,
  `overwrite_files`).
- **CI history:**
  - Run on `92ddf26`: packages built, but the installer ISO was 2.07 GiB → failed the size check.
  - Fixed in `c5f2b14`: the ISO now carries only TotV's own packages.
  - The run on **`f0377a6`** was in progress when this file was written. **Next step: check that
    run** (jobs iso → system → vm-test, and release). The `system` job had never run before:
    expect possible fixes there (docker on the runner, disk space under `/mnt`, the itch.io
    download, AppImage extraction in the chroot, `pacstrap -c`, `mksquashfs` exclusions,
    `xorriso`). The `vm-test` job had never run either.
- **Secrets the user may need to add:** `VOTV_URL` (a direct zip URL) or `ITCH_API_KEY`, if the
  itch.io page flow fails in CI. Without the game, the image builds with a warning, and the
  installed system then needs `sudo votv-os-game install`.
- **Never tested on real hardware or against the real game.** The mod has only run against
  `votv/tests/lua/mock_ue4ss.lua`. Risky points:
  - `RegisterHook` paths for `solar`/`virus_pb`;
  - the save-world function name;
  - `kwin_wayland --wayland-fd` with an absolute socket;
  - PAM ctypes in totvd;
  - the `PAMName=login` shell with User=votv;
  - the pipewire-pulse shared socket;
  - r2modman AppImage flags (`--no-sandbox --ozone-platform=wayland`);
  - the itch.io scraping.
- **Tests (run them after changes):**
  ```bash
  T=$(mktemp -d); VOTV_OS_RUNTIME=$T VOTV_OS_SAVES=$T VOTV_OS_SYSCFG=$T/none.json lua5.4 votv/tests/lua/test_mod.lua votv/mod/TotVOS/Scripts
  QT_QPA_PLATFORM=offscreen python3 -m unittest votv/tests/test_host.py
  python3 -m pyflakes votv/host/lib votv/tests/test_host.py
  shellcheck -S warning <the scripts listed in .github/workflows/votv.yml>
  ```
  Last results: 44 Lua checks pass, 12 host tests pass, lint is clean. Needed apt packages:
  lua5.4, shellcheck, libegl1, libgl1, libxkbcommon0, libfontconfig1, libdbus-1-3; pip: PyQt6,
  pyflakes.
- **Sandbox limits seen:** Arch mirrors and thunderstore.io were unreachable from the sandbox
  (so no local Arch builds); raw.githubusercontent.com and the GitHub API worked for public
  repos. `gh` may only be used for search; use the GitHub MCP tools for Actions logs.
