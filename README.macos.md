# The Sims 2 on Apple Silicon Macs

The Sims 2 Legacy Collection (Steam), statically recompiled from your own copy into native arm64 code and run on Metal.
No Wine, no Rosetta, no emulator. Nothing from the game is in this repository: the build regenerates everything locally
from your copy, and the game folder is only read.

Status and the work list: [docs/SIMS2-PORT.md](docs/SIMS2-PORT.md).

## Install

Needs an Apple Silicon Mac, the Xcode command line tools (`xcode-select --install`) and python3. The game is
Windows-only on Steam: copy its folder (`steamapps/common/The Sims 2 Legacy Collection`, about 13 GB) over from a PC,
or use a CrossOver Steam library.

```sh
git clone <this repository> && cd sims-2-macos
./install.sh --game-dir "/path/to/The Sims 2 Legacy Collection"
```

This recompiles the game (about fifteen minutes the first time; its analysis needs about 26 GB of memory) and installs
**The Sims 2 Native** in `~/Applications`. Settings, neighbourhoods and logs live in `~/Games/Sims2Native`
(the game's own folder is `drive_c/Users/player/Documents/EA Games/The Sims 2 Legacy` inside it).

`./install.sh --nightly` installs **The Sims 2 Nightly** next to it, built from the `nightly` branch (experimental
work), sharing the same neighbourhoods and settings.

## The launch window

- **Resolution**: Retina (every pixel of the display), the display in points, or a common size.
- **Display**: Interface Size (the game is laid out at the resolution divided by it, and the renderer draws at the
  full resolution, so the interface is larger while the 3D stays sharp; 200% on a Retina display is the game's layout
  in points), full screen or a window, below or around the notch, and the frame rate (the display's, 60 or 30).
- **Graphics** and **Detail**: the game's own options (material and object detail, shadows, lighting, effects,
  reflections, snow, ceilings, object hiding, opaque interface). Each starts at "Game's Setting", which leaves the
  choice made in the game's Options alone; another choice is applied every time the game starts (through its
  `userStartup.cheat`, as the properties its `Graphics Rules.sgr` sets for that level).
- **Camera**: edge scrolling and its speed, the idle camera drift and the special-event cameras.
- **Saves** opens the game's folder in Finder; **Updates** rebuilds the app from the newest version of this
  repository and your own copy of the game.

In the game: pinch on a trackpad, or scroll, to zoom; push the pointer against a screen edge to scroll.

## How it works

`recomp/` holds the recompiler (x86 → C, then clang) and the runtime: a macOS implementation of the Windows APIs the
game uses, Direct3D 9 on the Metal renderer in `src/` (the game's shaders translated with MojoShader), DirectSound on
Core Audio, and Winsock. Details in [recomp/README.md](recomp/README.md).

The Sims 2 is a trademark of Electronic Arts; this project is not affiliated with them. You need your own copy of the
game.
