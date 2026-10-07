# Dungeon Siege II — native Linux port

An experimental Linux port of [Dungeon Siege II for macOS](https://github.com/Joshspeakman/dungeon-siege-2-macos),
starting from upstream `3e3e47c`. The player's own x86 executable and Miles/Bink libraries are statically recompiled
into native code. The Linux host uses SDL2, OpenGL, FreeType/fontconfig and native sockets; it does not use Wine or Proton.

**This is an early development build, not feature parity with the Mac release.** The first supported executable is
GOG 2.3 (installer 37617). Steam base-game **data files** can be used with that build; the GOG executable remains
required for the base-game profiles. A separate [Broken World preview](docs/BROKEN_WORLD.md) is available on
the `nightly` branch. Its opening area, saving and ultrawide reloading have been exercised;
effects rendering and broader campaign/multiplayer validation remain unfinished.
No game executable, archive, generated game code, save, product key or proprietary DLL is distributed here.

**Nightly preview:** known rendering problems include large black polygons around transparent effects.
Startup and world loading can also be slow. Build this preview locally from your own game files;
see the [Broken World setup and known limitations](docs/BROKEN_WORLD.md).

## Current Linux status

- Native x86-64 build on CachyOS, tested with an RTX 3080 Ti.
- Main menu, character creation, opening movies and the opening campaign area render with the game's fixed-function graphics path. Campaign saving and loading have been exercised, including loading a GOG-data save with Steam base-game assets at 3440×1440.
- SDL input/audio host, Linux crash reports, archive loading, timers and exception handling. A recorded stereo audio output check contains non-silent PCM at 44.1 kHz.
- Mac-style launcher reads the logo and background from your own `Objects.ds2res`.
- **Test Lab** in the launcher: searchable travel points, gear, enemies, spells and powers; isolated save copies,
  invincibility, spell sequences and a visual-test log. See [test controls](docs/LINUX.md#test-lab).
- Display-resolution default, custom resolutions including ultrawide, display-synchronized/custom/unlimited FPS,
  fullscreen/windowed mode, and the Mac version's view-distance controls.
- DirectPlay and Winsock retained. Loopback packet tests pass with and without 20% simulated loss. **A real
  Linux/Mac/Windows multiplayer session has not yet been verified.**
- Renderer tests cover lighting modulation, fog, blending, gamma, partial depth clears, stencil and 3440×1440 / 5120×1440 presentation.

The Mac HLSL-to-Metal effects are retained in source. Linux currently disables their capability flag and uses the
original fixed-function fallback. Porting the effects compiler and programmable rendering path is outstanding.
The experimental DS1 shadow/DLSS changes are not included.

## Build and play

Dependencies: Clang, Python 3.11+, pip/venv, pkg-config, SDL2, FreeType, fontconfig, libsndfile, GLEW, libpng and zlib.
Pillow is needed to extract the app icon; the launcher also needs PySide6. Innoextract is needed only to extract a GOG offline installer.

On CachyOS/Arch:

```sh
sudo pacman -S --needed base-devel clang python python-pip python-pyside6 python-pillow \
  sdl2 freetype2 fontconfig libsndfile glew libpng zlib innoextract
```

From an extracted GOG folder:

```sh
./install.sh --game-dir "/path/to/Dungeon Siege II"
```

Or from your offline installer (the matching `.bin` must be beside it):

```sh
./install.sh --gog-installer "/path/to/setup_dungeon_siege_ii_2.3_(37617).exe"
```

This builds locally, installs **Dungeon Siege II (Linux Preview)** in the application menu, and creates
`~/.local/bin/dungeon-siege-2-linux`. Saves and settings go under
`~/.local/share/dungeon-siege-2-linux/drive_c/Users/player/Documents/My Games/Dungeon Siege 2/` by default;
`--data-dir` selects a different location. Original game folders are only read.
The application-menu, launcher and game-window icons come from your own executable at build/install time;
the artwork is not distributed in this repository.

To include your Steam base-game data as a second launcher choice:

```sh
./install.sh --game-dir "/path/to/extracted/GOG/game" --steam-data "/path/to/Steam/Dungeon Siege 2"
```

This creates a separate view of the base-game archives and map. Added Broken World archives and mods are excluded
from that view; their originals are untouched. This is **not a Steam-only build**: both choices use the native code
recompiled from your GOG executable. See [edition notes](docs/LINUX.md).

For development, without installation:

```sh
recomp/build.sh "/path/to/GOG/DungeonSiege2.exe" recomp/work/gog
recomp/run.sh "/path/to/GOG/game" recomp/work/gog
# Rebuild just the runtime / renderer / host after editing them:
recomp/tools/build_linux.sh recomp/work/gog
```

`DS_BUILD_JOBS=8` limits compilation concurrency. Generated files remain in ignored build directories.
F11 toggles fullscreen; F12 releases/captures the mouse. For online play, the launcher accepts your own retail CD key
and stores only the same hash as the Mac port, in a file readable only by your account. See the upstream
[multiplayer notes](docs/MULTIPLAYER.md); the online service and cross-platform gameplay still need Linux validation.

In the launcher, **Frame Rate → 244 FPS** sets a 244 FPS limit, and **Unlimited** removes the frame cap.
Both turn off VSync so display refresh does not impose another limit. **Resolution** includes 2560×1080,
3440×1440, 3840×1600, 5120×1440 and 5120×2160, plus custom sizes. The 3D world renders at the selected
resolution; original 4:3 menus keep their proportions. A render size wider than your current monitor is scaled
to fit with borders. The display's own resolution remains the default.

## Verification and next steps

```sh
recomp/tests/check_linux.sh
# Headless graphics testing:
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 recomp/tests/check_linux.sh
```

These checks require no game files. CI runs the same platform, transport and graphics checks with Mesa.
For game-driven tests, use `DS_TEST=1`, `DS_EXIT_AFTER=<seconds>`, `DS_SCRIPT` and `DS_CMDFILE` as described in
[the recompiler notes](recomp/README.md). Test data folders must be separate from personal saves.

Outstanding: broader campaign/save/audio validation, shader effects,
additional executable profiles, broader Broken World campaign validation, and actual Linux ↔ Mac ↔ Windows hosting/joining tests.

The [original Mac README](README.macos.md), [recompiler design](recomp/README.md), and upstream history are retained.
