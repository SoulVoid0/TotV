# Voices of the Void on TotV OS

The integration between TotV OS (`os/`) and **Voices of the Void Alpha 0.9.0n**. Its only
game-side dependency is [unreal-shimloader](https://thunderstore.io/c/voices-of-the-void/p/Thunderstore/unreal_shimloader/).

| What you get | How |
|---|---|
| The OS boots straight into a VotV save named after the user chosen in the installer | tty1 autologin → `votv-os-session` → game via LSIW → the mod loads/creates slot `<story prefix><SAVE_NAME>` from `/etc/totv/user.conf` and skips the menu |
| The in-game PC is a KDE Plasma desktop, and that desktop is the OS desktop | a KDE Plasma session runs inside the OS compositor; the mod draws it on every in-game laptop / portable PC screen and, when you use the PC, the real desktop covers the in-game screen at native resolution and frame rate |
| In-game screens line up with your real monitor | when you use the PC the camera moves to a pose in front of the in-game screen; **VotV Screen Setup** (on the KDE desktop) moves, tilts and zooms it live until the in-game screen matches your monitor |
| A KDE app with everything the game's own PC did | **VotV PC** on the KDE desktop mirrors the game's PC UI (every tab: email, store, upgrades, cameras, drives, signals, power...) and presses its buttons, types into its fields and moves its sliders through the game's own handlers |
| Inventory on a second monitor | with 2+ monitors, opening the inventory in game shows it full-screen on the second monitor (VotV Inventory) instead of over the 3D view; with one monitor it opens normally |
| Performance | only settings that change no pixel: threaded GC destruction, no forced GC after streaming, VRAM-bounded texture streaming, parallel animation, PSO cache, DXVK state cache, gamemode, fsync; and while the KDE desktop covers the game the hidden 3D view renders at reduced cost |

**Meta+Esc** leaves the in-game PC (or let the game close it as usual).

## Layout

```
votv/
  mod/TotVOS/Scripts/   the UE4SS Lua mod (loaded by shimloader)
    main.lua            wiring, 50 ms loop on the game thread
    autoload.lua        boot into the user's save
    pcscreen.lua        KDE desktop on the in-game PC, camera alignment
    relay.lua           VotV PC relay + second-screen inventory
    widgetmirror.lua    generic UMG mirroring and actions
    perf.lua            invisible performance settings
    ipc.lua, config.lua, util.lua, json.lua
  mod/manifest.json, package.sh   Thunderstore package (depends on Thunderstore-unreal_shimloader)
  host/                 everything on the Linux side; install.sh is the TotV OS installer hook
    bin/votv-os-session         tty1 → kwin_wayland (DRM) with the votv-os-wm script
    bin/votv-os-session-main    bridge + PC desktop + inventory app + the game (restarts it after a crash)
    bin/votv-pc-session         the KDE "PC": nested kwin_wayland + plasmashell, own D-Bus bus
    bin/votv-os-launch-game     LSIW (GE-Proton, else Wine) + shimloader args + DXVK/env tuning
    bin/votv-os-install-game    unpack the game to /opt/votv and add shimloader
    bin/votv-os-fetch-deps      download shimloader (Thunderstore, else its GitHub repo)
    lib/votvos/                 Python (PyQt6): bridge daemon, frame capture, apps
    kwin/votv-os-wm/            KWin 6 script: where each window goes; Meta+Esc
  tests/                mod tests against a mock UE4SS API; host unit tests
```

## How the pieces talk

```
  VotV (Wine/Proton, UE4SS + TotVOS mod)
      │  C:\run\user\<uid>\votv-os\   (LSIW: C:\ is /, so this is $XDG_RUNTIME_DIR/votv-os)
      │    game-events.jsonl  ─────────►  votv-os-bridge  ◄──D-Bus──  votv-os-wm (KWin script)
      │    host-commands.jsonl ◄────────    │  screens.json, pc-frame.json + frames/*.bmp
      │    laptop-ui.json / inventory-ui.json ──► VotV PC / VotV Inventory apps
      │
  kwin_wayland (real screens) ── game fullscreen on the primary monitor
                              ── nested kwin_wayland "votv-pc" running plasmashell (the PC)
                              ── votv-inventory fullscreen on the second monitor
```

* **Using the PC.** The mod sees `mainPlayer_C.activeInterface` become a `ui_laptop_C`, moves the
  view to a `CameraActor` in front of that screen's `WidgetComponent` (distance from the screen
  width and FOV, plus your calibration), and emits `pc_active`. After the camera blend the bridge
  tells KWin to raise the PC desktop fullscreen on the primary monitor and focuses it. Meta+Esc (or
  the game closing the interface) reverses it.
* **From afar.** The bridge grabs the PC desktop through KWin's ScreenShot2 D-Bus API on the
  nested session (spectacle as fallback), only when it changed, at `pc.ingame_fps` (default 2),
  and writes a BMP. The mod loads it with `KismetRenderingLibrary.ImportFileAsTexture2D` into a
  full-size `Image` it added on top of each laptop's UI.
* **Boot.** Same path the game's own menu uses: `LoadGameFromSlot` (or `CreateSaveGameObject` for a
  first boot), `mainGameInstance_C.setSaveSlotObject`, `loadObjects`, game rules and start day,
  `GameMode`, then `open untitled_1`.

Game class and function names (`mainGamemode_C.laptop/propInventory/mainPlayer`,
`mainPlayer_C.activeInterface`, `ui_saveSlots_C.getSavePrefix`, `ui_playerInventory_C.exit`,
`ui_laptop_C.switcher`, ...) are the ones the
[Multivoid](https://github.com/VOTV-MP/Multivoid) project reverse-engineered for 0.9.0n.

## Settings

`/etc/totv/votv.json` (system) and `~/.config/totv/votv.json` (VotV Screen Setup writes this one);
both are read live. Defaults are in `host/lib/votvos/config.py` and `mod/TotVOS/Scripts/config.lua`.

| Key | Default | |
|---|---|---|
| `autoload.enabled` / `autoload.mode` | `true` / `0` | 0 Story, 1 Infinite, 3 Custom, 4 Sandbox |
| `pc.replace_ingame_ui` | `true` | the KDE desktop on in-game PCs |
| `pc.ingame_fps`, `pc.ingame_width` | `2`, `1024` | refresh rate and width of the in-game screen picture |
| `pc.align_camera`, `pc.blend`, `pc.overlay_delay` | `true`, `0.35`, `0.4` | |
| `pc.camera.*` | 0 | `distance_scale`, `offset_right/up/forward` (cm), `pitch/yaw/roll` (°), `fov` (0 = the game's) |
| `inventory.second_screen` | `auto` | `auto` (2+ monitors), `on`, `off` |
| `perf.enabled` | `true` | |

## Installing

The TotV OS installer runs `host/install.sh` with the target root (see `os/`). By hand on a TotV OS
system: `sudo votv/host/install.sh /`, then `sudo votv-os-install-game /path/to/votv-0.9.0n.zip`.
The game itself is not redistributable, so the installer asks for your copy.

As a plain mod (any OS, through r2modman/Thunderstore Mod Manager): `votv/mod/package.sh` builds
`TotV-TotVOS-1.0.0.zip`. Without the TotV OS bridge running the mod does nothing: no autoload,
no overlay, no camera change, inventory unchanged.

## Tests

```
lua5.4 votv/tests/lua/test_mod.lua votv/mod/TotVOS/Scripts      # with VOTV_OS_RUNTIME etc., see the CI workflow
QT_QPA_PLATFORM=offscreen python3 -m unittest votv/tests/test_host.py
```

## Limits (read this)

* **Not run against the real game here.** The build environment has neither the game (it is
  downloaded from itch.io) nor a GPU. The mod is exercised against a mock of the UE4SS API, and its
  game-facing names come from Multivoid's work on 0.9.0n. Every game call is guarded, so a wrong
  name disables one feature and logs `[TotVOS] WARN ...` in `UE4SS.log` instead of crashing. Check
  that log on the first boot.
* **The in-game screen seen from afar is a slideshow** (2 fps by default, only when the desktop
  changes). Lua cannot stream video into a texture; that needs a UE4SS C++ mod built with MSVC
  against UE4SS's SDK. While you use the PC you see the real desktop at full speed, so this only
  affects the screen in the corner of your eye.
* **VotV PC mirrors structure, not pictures**: text, buttons, fields, checkboxes, sliders, lists and
  tabs. Camera feeds, signal waveforms and item icons are not mirrored. Clicks outside a known
  control are sent as a pointer tap through the player's WidgetInteraction component (best effort).
* **Second-screen inventory** shows the game's inventory screen while it is open, as names and
  buttons (no icons). The game keeps the cursor while it is open, as it does without the mod.
* **Camera alignment** needs a one-time calibration per monitor in VotV Screen Setup; the defaults
  frame the screen edge to edge at the game's FOV.
* **Graphics**: AMD and Intel (Mesa Vulkan) are installed by default. NVIDIA needs the
  proprietary driver added to the OS image.
