# Recompiler and runtime: The Sims 2 as native code

Static recompilation of the user's own Steam copy of The Sims 2 Legacy Collection (`EP9/TSBin/Sims2EP9.exe`, and
`ijl15.dll` from its folder) into C, compiled for Apple Silicon (Metal) or Linux x86-64 (SDL/OpenGL). Nothing derived
from the game is committed: the scripts regenerate everything under `recomp/work/` (git-ignored) from the user's files.
Installing and playing: the [root README](../README.md). The port's notes and open work:
[docs/SIMS2-PORT.md](../docs/SIMS2-PORT.md).

This tree was inherited from the author's Dungeon Siege II and Fallout: New Vegas ports. Their scripts and runtime files
(`build.sh`, `build_fnv.sh`, `ds2_imports.c`, `fnv_imports.c`, ...) are still here, but The Sims 2 build doesn't use
them.

## Building by hand

`install.sh` does all of this. By hand:

```sh
recomp/build_sims2.sh "/path/to/The Sims 2 Legacy Collection"     # -> recomp/work/sims2/ (on Linux: app/Sims2Linux)
recomp/tools/build_app.sh recomp/work/sims2                          # Mac: host, Metal renderer, launch window -> app/Sims2Native
```

`build_sims2.sh` checks `Sims2EP9.exe` (SHA-256 `24041f83…156b6`), unwraps Steam's SteamStub 3.1 wrapper from a copy
(`tools/steamstub.py`; the result is checked too), then:

| Step | Tool | Notes |
|---|---|---|
| Analysis | `tools/analyze.py` | 109,632 functions, 97.3% of `.text`; about 26 GB of RAM at its peak. Reused when `analysis.json` is at least as new as `analyze.py`; the cache does not check the executable. `analysis.log` is also required. Use `SIMS2_REANALYZE=1` after changing inputs. |
| Lifting | `tools/lift.py --game sims2` | one C function per original function; the game-specific overrides and hooks are in `lift.py` and `runtime/win32/hooks.c` |
| `ijl15.dll` | the same tools | the Intel JPEG Library, lifted into the same image set at its own base |
| Compiling | `tools/cc1.sh` | only files whose C changed are recompiled (`SIMS2_BUILD_JOBS=n` sets the parallel jobs) |
| Runtime | `tools/build_runtime.sh` | the Windows runtime (on Linux also the host and the link); `SIMS2_RELINK=1 build_sims2.sh ...` redoes only this after runtime-only changes |

`SIMS2_ANY_BUILD=1` skips the executable checks (unsupported).

## What's where

- `tools/`: the recompiler (`analyze.py`, `lift.py`, `sse.py`, `link_tables.py`), `steamstub.py`, the app helpers
  (`build_app.sh`, `extract_icon.py`, `sims2_art.py`, `nightly_icon.m`).
- `runtime/rt.c`, `rt.h`, `rt_sse.h`: the execution model below. `runtime/edition.h`: the per-game profile
  (`SIMS2_EDITION`).
- `runtime/win32/`: the Windows APIs: loader, memory, heaps, threads, SEH, files (copy-on-write into the data folder),
  registry (filled from Steam's `3314070_install.vdf`), USER32, GDI, Direct3D 9 (`d3d9*.c`, with fixed-function stages
  and CPU vertex processing), DirectSound, DirectInput, Winsock, and the game's own imports and offline Steam
  (`sims2_imports.c`). `refpack.c` is a native RefPack compressor, `sims2_texture_cache.c` the texture block cache.
- `host/main.m` and `host/sims2_launcher.m`: the Mac host and launch window. `../src/renderer`: the Metal renderer.
  `host/linux.c`: the Linux host.
- `third_party/`: MojoShader (the game's shaders to Metal) and minimp3.

## Execution model

- **Memory:** one 4 GB host region; guest address = offset. The image sits at its preferred base (`0xA0000000`), so
  the pointers the game stores keep their 32-bit values.
- **Functions:** one C function per original function. Registers are C locals, written back to a per-thread context
  around calls. The guest stack is real, so calling conventions, `this` pointers and stack-walking code behave as
  before.
- **Flags:** lazy: flag-setting instructions record their operands; consumers compute only the flags they need.
- **x87:** eight doubles with TOP and the control/status words; transcendentals use the host math library.
- **Memory ordering:** on arm64 every guest access keeps x86's ordering (`RT_TSO`: acquire loads, release stores).
- **Indirect calls and jumps:** an address to function table; jump tables become `switch` statements; imports go
  through `rt_import`.
- **Exceptions:** SEH through the game's own handlers; C++ `catch` blocks resume at their continuations.
- **CPU:** `cpuid` reports an SSE2-only Intel CPU, so the executable's 3DNow!, SSE4 and AVX paths are never taken.
  Instructions the lifter doesn't support become traps that name their address.

## Testing

- `bash recomp/tests/check_macos.sh`: CPU, failure-injection, host and synthetic Metal pixel tests on a Mac. No game
  files needed; it also runs in CI.
- `recomp/tests/check_linux.sh`: the Linux equivalent (CI).
- Instruction fuzzers against Unicorn (`tests/fuzz_sse.py`, `tests/fuzz_insn.py`) and `tools/import_gap.py`: see
  "Tests" in [docs/SIMS2-PORT.md](../docs/SIMS2-PORT.md).
- Test mode: `DS_TEST=1` (an ordinary background window, no mouse capture, no launch window), `W32_AUDIO_MUTE=1`,
  `DS_RESOLUTION=WxH`, `DS_SCRIPT="@145:tap:648,380;@160:shot:/tmp/a.png"` (scripted input at presented frames) and
  `DS_CMDFILE=<file>` (commands appended while the game runs). `tools/sims2_iterate.sh` runs a short session on Linux
  (set `GAME` to your game folder). Development switches for the renderer and caches are listed in the port notes.
