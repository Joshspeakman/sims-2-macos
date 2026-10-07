# Dungeon Siege II for Apple Silicon Macs

Dungeon Siege II (GOG release 2.3), statically recompiled from your own copy into native arm64 code and run on Metal,
as [dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos) does for Dungeon Siege 1. No Wine, no
Rosetta, no emulator. Nothing from the game is in this repository: the build regenerates everything locally from your
copy, and the game folder is only read.

**State: Beta 1.** Single player is playable: main menu, hero creation, the intro movie and opening cutscene,
gameplay (world, characters, HUD, dialogue), saving and loading, at the display's own resolution and up to 120 fps.
The game's shader effects (Options → Video → Shaders: water, refraction, glow, heat shimmer) are translated to Metal,
and a View Distance setting pushes out each area's fog like the SeeFar mods. Multiplayer is switched back on and signs
in to OpenSpy with an original retail CD key; hosting and joining games are not tested yet
([docs/MULTIPLAYER.md](docs/MULTIPLAYER.md)). What's next: [docs/PLAN.md](docs/PLAN.md).

## Install

Needs an Apple Silicon Mac, the Xcode command line tools (`xcode-select --install`) and python3.

```sh
git clone <this repository> && cd dungeon-siege-2-macos
./install.sh --gog-installer ~/Downloads/setup_dungeon_siege_2_*.exe   # GOG offline installer (brew install innoextract)
# or, with the game already unpacked or installed somewhere:
./install.sh --game-dir "/path/to/Dungeon Siege 2"
```

This recompiles the game (a few minutes) and installs **Dungeon Siege II Native** in `~/Applications`. Settings, saves
and logs live in `~/Games/DungeonSiege2Native`. The launch window picks the resolution, view distance and frame rate, takes a CD key for online play, and offers
updates: it rebuilds the app from the newest version of this repository and your own copy of the game.

`./install.sh --nightly` installs **Dungeon Siege II Nightly** next to it, built from the `nightly` branch (experimental
work), sharing the same saves and settings.

## How it works

`recomp/` holds the recompiler (x86 → C, then clang) and the runtime: a macOS implementation of the Windows APIs the
game uses, Direct3D 9 and D3DX on the Metal renderer in `src/`, Winsock, Miles audio and Bink video (both recompiled
from the DLLs in your game folder). Details in [recomp/README.md](recomp/README.md).

Dungeon Siege II is a trademark of its owners; this project is not affiliated with them. You need your own copy of the
game.
