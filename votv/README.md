# Voices of the Void on TotV OS

The integration between TotV OS (`os/`) and **Voices of the Void Alpha 0.9.0n**. Its only
game-side dependency is [unreal-shimloader](https://thunderstore.io/c/voices-of-the-void/p/Thunderstore/unreal_shimloader/).
Voices of the Void is a core part of the OS: it lives in `/.VotV/<version>/`, runs from boot as
the `votv` system user, and every change to the game is made through the **TotVOS** mod.

| What you get | How |
|---|---|
| No main menu | the mod hides it and loads the save the OS chooses (`target.json`); if the game falls back to its menu (quit, death) the save comes back |
| The **Home** game mode | a world on the Infinite base with the **real-life clock**, **never hungry or tired**, and **power that never goes out** (blackouts, the virus lockout and broken generators are undone at once) |
| Boot into the shared Home save `default` | `totv-shell.service` → the game → `default`, shared by every user |
| Log in on the in-game PC → your own save | the in-game PC shows the login screen; `totvd` checks the password (PAM) and starts your KDE desktop; the game saves `default` and loads the save named after you |
| The in-game PC is a KDE Plasma desktop, the OS desktop | your desktop (a nested KWin in the shell) is drawn on every in-game laptop / portable PC; when you use the PC the real desktop covers the in-game screen at native resolution |
| In-game screens line up with your monitor | when you use the PC the camera moves in front of the screen; **VotV Screen Setup** calibrates it live |
| **VotV Saves** | create (Home, Story, Infinite, Custom, Sandbox, with rules), rename, duplicate, delete and load saves; loading moves you into that save at once |
| **VotV Mods** | download and install Thunderstore mods (with dependencies) into the r2modman profile while the game runs; **Apply mods** restarts TotV so the game starts with them |
| **r2modman** | installed in `/.VotV/r2modman`, set up for Voices of the Void (profile `Default`, shimloader, TotVOS); not needed for playing: the game loads the profile itself |
| **VotV PC** | the game's own PC (every tab) mirrored and driven from the KDE desktop |
| Inventory on a second monitor | with 2+ monitors the inventory opens full-screen on the second one |
| Performance | only settings that change no pixel: threaded GC destruction, no forced GC after streaming, VRAM-bounded streaming, parallel animation, PSO cache, DXVK state cache, gamemode, fsync; while the KDE desktop covers the game the hidden 3D view renders at reduced cost; r2modman does not run while you play |
| System resources | the game and r2modman run as `votv` in `totv-core.slice`: System Monitor lists them as system processes |

**Meta+Esc** leaves the in-game PC (or let the game close it as usual).

## Layout

```
votv/
  mod/TotVOS/Scripts/   the UE4SS Lua mod (loaded by shimloader)
    main.lua            wiring, 50 ms loop on the game thread
    saves.lua           no main menu; converges on target.json; saves before a switch
    home.lua            the Home game mode
    pcscreen.lua        KDE desktop on the in-game PC, camera alignment
    relay.lua           VotV PC relay + second-screen inventory
    widgetmirror.lua    generic UMG mirroring and actions
    perf.lua            invisible performance settings
    ipc.lua, config.lua, util.lua, json.lua
  mod/manifest.json, package.sh   Thunderstore package (depends on Thunderstore-unreal_shimloader)
  host/                 the Linux side, packaged as votv-os (os/packages/votv-os)
    install.sh          files (--files-only, for the package) and the setup of a system root
    systemd/            totv-shell, totvd, totv-desktop@, totv-r2modman@, totv-update*, totv-core.slice
    bin/votv-os-session          the shell: kwin_wayland on the screens, socket /run/totv/shell/wayland-0
    bin/votv-os-session-main     bridge + login screen + inventory + the game (kept running)
    bin/votv-pc-session          a user's KDE desktop on the in-game PC (nested KWin + plasmashell)
    bin/votv-os-launch-game      LSIW (GE-Proton, else Wine) + the r2modman profile's shimloader folders
    bin/votv-os-game             download Voices of the Void (itch.io) / update it
    bin/votv-os-install-game     install a build into /.VotV/<version>, add shimloader
    bin/votv-os-r2modman         install / update r2modman, seed its profile, run it
    bin/votv-os-fetch-deps       download shimloader
    lib/votvos/                  Python (PyQt6): bridge, totvd, saves, mods, apps
    kwin/votv-os-wm/             KWin 6 script: where each window goes; Meta+Esc
  tests/                mod tests against a mock UE4SS API; host unit tests
```

## How the pieces talk

```
  Voices of the Void (as votv; Wine/Proton via LSIW; UE4SS + TotVOS from the r2modman profile)
      │  Z:\run\totv\votv-os\  (= /run/totv/votv-os, group votv)
      │    game-events.jsonl   ─────────►  votv-os-bridge (votv)  ◄─D-Bus─  votv-os-wm (KWin script)
      │    host-commands.jsonl ◄─────────    │ screens.json, target.json (which save runs)
      │    target.json ◄──── VotV Saves (user) / the bridge at login and logout
      │    session.json ◄─── totvd (root): who is logged in
      │    pc-frame.json + frames/*.bmp ◄── votv-login (nobody logged in) / votv-pc-agent (in your desktop)
      │    laptop-ui.json / inventory-ui.json ──► VotV PC / VotV Inventory
      │
  TotV shell: kwin_wayland on the real screens (votv, totv-shell.service, tty1)
      ── the game, fullscreen on the primary monitor
      ── the PC: the login screen, or totv-desktop@<user> (nested kwin_wayland + plasmashell, as the user)
      ── votv-inventory, fullscreen on the second monitor
      ── r2modman (totv-r2modman@<user>, as votv) shows on the user's desktop (/run/totv/pc/<user>/wayland-0)
```

* **Saves.** `/.VotV/saves/registry.json` records each save (title, mode, owner; `default` is
  shared, `<user>` is the user's own). The game's file is `<the game's prefix for the mode><name>.sav`
  in `/.VotV/saves/games`; the mod learns the prefixes from the menu once (`prefixes.json`).
  Switching: the mod calls the game's own save function, then loads the target exactly as the
  menu does (`LoadGameFromSlot`/`CreateSaveGameObject`, `setSaveSlotObject`, rules, `open untitled_1`).
* **Home mode.** `daynightCycle_C.day` follows the local time (calibrated from the cycle's own
  `timeZ`; `TimeScale` is trimmed to real-time pace), `saveSlot_C.food/sleep` stay at 100 and the
  pawn's drains at 0, post-hooks on `powerControl_C.solar` / `virus_pb` and a 200 ms watch undo
  every blackout and fix broken `generator_C`s.
* **Mods.** The game starts with shimloader's `--mod-dir/--pak-dir/--cfg-dir/--overlay-dir` set to the
  r2modman profile, the same arguments r2modman uses, so r2modman does not need to be open.
  VotV Mods installs into the same profile in r2modman's layout and writes its `mods.yml`;
  *Apply mods* saves the world and restarts TotV.

Class and function names come from the [Multivoid](https://github.com/VOTV-MP/Multivoid)
project's reverse-engineering of 0.9.0n (`mainGamemode_C`, `mainPlayer_C.activeInterface`,
`ui_saveSlots_C.getSavePrefix`, `daynightCycle_C`, `powerControl_C`, `generator_C`,
`mainGameInstance_C.save_gameInst`...).

## Settings

`/etc/totv/votv.json` (system) and `/.VotV/config/<user>.json` (VotV Screen Setup writes it);
both are read live. Defaults: `host/lib/votvos/config.py`, `mod/TotVOS/Scripts/config.lua`.

| Key | Default | |
|---|---|---|
| `saves.user_mode` | `home` | the mode of a user's own save when it is created |
| `saves.save_before_switch`, `saves.hide_menu` | `true` | |
| `home.base_mode` | `1` | the game mode under Home (1 Infinite, 3 Custom, 4 Sandbox) |
| `home.realtime`, `home.no_needs`, `home.power_always_on` | `true` | the Home rules |
| `mods.profile` | `Default` | the r2modman profile the game loads |
| `game.engine` | `auto` | `auto` (GE-Proton if LSIW has it, else Wine), `wine`, `proton`, `proton:VERSION` |
| `game.follow_latest` | `false` | `totv-update` installs new game builds |
| `pc.replace_ingame_ui`, `pc.ingame_fps`, `pc.ingame_width` | `true`, `2`, `1024` | the in-game screen picture |
| `pc.align_camera`, `pc.blend`, `pc.overlay_delay`, `pc.camera.*` | | camera alignment |
| `inventory.second_screen` | `auto` | `auto` (2+ monitors), `on`, `off` |
| `perf.enabled` | `true` | |

## Command line

```
votv-saves list | load NAME | home | new TITLE MODE
votv-os-ctl restart-game | apply-mods | r2modman | logout | update | status
votv-os-game status | latest | install | update [--check]
sudo totv-adduser [--admin] NAME
```

## Tests

```
lua5.4 votv/tests/lua/test_mod.lua votv/mod/TotVOS/Scripts      # VOTV_OS_RUNTIME, VOTV_OS_SAVES: see the CI workflow
QT_QPA_PLATFORM=offscreen python3 -m unittest votv/tests/test_host.py
```

## Limits (read this)

* **Not run against the real game here.** The build environment has neither the game nor a GPU.
  The mod is exercised against a mock of the UE4SS API; its game-facing names come from
  Multivoid's work on 0.9.0n. Every game call is guarded, so a wrong name disables one feature and
  logs `[TotVOS] WARN ...` in `UE4SS.log` (next to `VotV-Win64-Shipping.exe` in `/.VotV/current`).
* **Saving before a switch** calls the first of `saveGame`/`saveAll`/`saveWorld`/`save` the game's
  `mainGamemode_C` has; if none exists the log says so and the world is not saved first.
* **Home power**: blackouts from `solar()`, the virus lockout and broken generators are undone; an
  event that turns lights off some other way is not covered.
* **The in-game screen seen from afar is a slideshow** (2 fps by default, only when the desktop
  changes): Lua cannot stream video into a texture.
* **VotV PC mirrors structure, not pictures**; the second-screen inventory shows names and buttons.
* **The game download** uses itch.io's page flow for free games; if itch.io changes it, set
  `VOTV_URL` (or `ITCH_API_KEY`) for the image build, or install a zip with
  `sudo votv-os-install-game FILE`. The game is free (name your own price) from its developer;
  whether the system image may be redistributed with the game in it is the publisher's call.
* **r2modman's "Start modded"** asks once for the game folder: choose `/.VotV/r2modman/launch`
  (its `VotV.exe` restarts the system's game with the profile).
* **Graphics**: AMD and Intel (Mesa Vulkan) are installed. NVIDIA needs the proprietary driver.
