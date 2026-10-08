# The Sims 2 for Apple Silicon Macs

The Sims 2 Legacy Collection (Steam), statically recompiled from your own copy into native arm64 code, to run on
Metal. No Wine, no Rosetta, no emulator. It's built on the recompiler and Windows runtime of
[fallout-nv-macos](https://github.com/Joshspeakman/fallout-nv-macos) (its README is now
[docs/FNV-README.md](docs/FNV-README.md)), which itself comes from the Dungeon Siege ports. Nothing from the game is in
this repository: the build regenerates everything locally from your Steam files, and the game folder is only read.

**State: decompiling (2026-10-07).** The Steam executable is unwrapped from its DRM, and all 109,632 of its functions
plus the Intel JPEG library lift to C and compile. The game doesn't link or run yet: it needs a Sims 2 profile in the
runtime, an offline Steam shim, and about 175 more Windows functions. Status, findings and the work list are in
[docs/SIMS2-PORT.md](docs/SIMS2-PORT.md).

## Build the C

Needs python3 and clang (on a Mac, the Xcode command line tools), and The Sims 2 Legacy Collection installed by Steam
(on a Mac, copy the folder over from a PC or Steam/CrossOver install).

```sh
recomp/build_sims2.sh "/path/to/steamapps/common/The Sims 2 Legacy Collection"
```

This checks `EP9/TSBin/Sims2EP9.exe` against the build the port was made from, removes Steam's wrapper
(`recomp/tools/steamstub.py`), then analyses, lifts and compiles the executable and `ijl15.dll` into
`recomp/work/sims2/`. On a 24-core PC that takes about 8 minutes, and the analysis needs about 26 GB of memory.

## How it works

`recomp/` holds the recompiler (x86 → C, then clang) and the runtime: an implementation of the Windows APIs the game
uses, Direct3D 9 on the Metal renderer in `src/` (the game's own shaders translated with MojoShader), DirectSound on
Core Audio, and Winsock. Details in [recomp/README.md](recomp/README.md).

The Sims 2 is a trademark of Electronic Arts; this project is not affiliated with them. You need your own copy of the
game.
