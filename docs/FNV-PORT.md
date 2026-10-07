# Fallout: New Vegas: native port with the Dungeon Siege II recompiler

This branch takes the static recompiler from this repository (x86 → C → clang) and points it at the player's own
**GOG Fallout: New Vegas 1.4.0.525** `FalloutNV.exe`
(sha256 `89e7020487e80f20ddc92ea641c4433b2c6839a82f45a076e414d167d11dd0fe`, installer
`setup_fallout_new_vegas_1.4.0.525_(12010).exe`). As with Dungeon Siege, nothing from the game is committed. All
generated code goes under `recomp/work/`, which git ignores.

## Status (2026-10-06, done on Linux x86-64)

| Step | State |
|---|---|
| Analysis (`tools/analyze.py`) | 92,603 functions, 95.6% of `.text`; 1,323 jump tables resolved, 127 unresolved (87 bounded heuristically while lifting) |
| SSE/SSE2/MMX in the lifter (`tools/sse.py`, `runtime/rt_sse.h`) | **new**. FNV runs about 250k SSE instructions; DS2 had none. XMM/MMX/MXCSR are in `Ctx`. All 375 sampled SIMD instances (every distinct form FNV uses, up to 3 each) match Unicorn bit for bit (`tests/fuzz_sse.py`, 37,440 random runs in total) |
| Integer/x87 lifter on FNV's instruction mix (`tests/fuzz_insn.py`, first run on a non-DS executable) | 11,942 instances × 20 runs. One real bug found and fixed: `shrd`'s overflow flag. Also added: 16-bit `mul`/`imul`/`div`/`idiv`, and `xchg` with memory as an atomic swap. Remaining differences are expected: x87 transcendentals (`fprem`/`fyl2x`/`f2xm1`, last-bit differences from the double model) and `cpuid` (a fixed fake CPU). That fuzzer does not seed XMM state, so its SSE rows are not meaningful; `fuzz_sse.py` covers SSE |
| Lifting (`tools/lift.py --game fnv`) | all 92,603 functions lifted, 0 internal errors. What's left unsupported is data decoded as code (`in`/`out`/`hlt`/far jumps/segment registers/`enter` nesting, about 330 sites) |
| Compiling the generated C | **all files compile** (FNV + Bink: 93,440 functions, 236 objects) with the project's flags (`-O2 -ffp-contract=off`), 0 errors, ~900 MB of C, ~1.5 min on 24 cores |
| Bink (`binkw32.dll` from the game folder) | lifted into the same image set as DS2's Bink (`build_fnv.sh`); every one of its imports is already implemented |
| Linking / running | **not yet**: see "Runtime gaps" |
| Shaders → Metal | **15,775 of 15,791** `.sdp` shader entries (1,809 unique bytecodes, vs_1_1 to ps_3_0) translate to MSL with MojoShader plus `tools/mojoshader-metal-centroid.patch`. The only failure is `PARTICLE.vso` (indexed constant array). The MSL has **not** been compiled with `xcrun metal` yet: that needs the Mac |

The installer (split zip) is attached to this repository's `game-installer` release. Its notes show how to join and
extract it, and the release is not part of the git history.

Build the C (Mac or Linux):

```sh
recomp/build_fnv.sh "/path/to/Fallout New Vegas/FalloutNV.exe"      # -> recomp/work/fnv/c/*.c and obj/
```

**Not re-run yet: the Dungeon Siege II build.** These changes are additive (`--game` defaults to `ds2`, and
`rt_cpuid_sse2` is off by default), but on the Mac run DS2's `recomp/build.sh` once as a regression check.

## What carries over unchanged from DS2

The execution model (guest memory at the PE's base, real guest stack, lazy flags, x87 as doubles), the Win32 layer
(loader, heaps, threads, SEH, files, registry, USER32/GDI), D3D9 device/surfaces/textures/buffers/state blocks/queries,
D3DX texture loading, DirectSound on Core Audio, Winsock and the Metal renderer.

## Runtime gaps, roughly in order of the work

1. **Start-up glue for a second game.** `runtime/win32/run.c`, `loader.c`, `edition.h`, `files.c` and the host app
   assume Dungeon Siege II (window title, paths such as `C:\GOG Games\Dungeon Siege`, `DungeonSiege2.exe`, the DS2
   `HOOKS`/`OVERRIDES` in `lift.py`, which `--game fnv` now turns off). FNV needs its own profile: exe name, game
   folder → `C:\Games\Fallout New Vegas`, `My Games\FalloutNV` for `Fallout.ini`/saves, registry key
   `HKLM\Software\Bethesda Softworks\FalloutNV\Installed Path`.
2. **Imports not implemented yet.** 111 of FalloutNV.exe's 280 imports are missing:
   - KERNEL32 (20): `CreateSemaphoreA`/`ReleaseSemaphore`, `TryEnterCriticalSection`,
     `InitializeCriticalSectionAndSpinCount`, `InterlockedCompareExchange`/`InterlockedExchangeAdd`,
     `GetPrivateProfile*`/`WritePrivateProfileStringA` (the INI files), `GlobalMemoryStatusEx`, `GetFileSizeEx`,
     `SetFilePointerEx`, `SetThreadIdealProcessor`, `GetCommandLineW`, `GetModuleHandleW`, console calls.
   - WSOCK32 by ordinal (21): DS2's `winsock.c` has these by name; map the ordinals.
   - DSOUND `#11` (`DirectSoundCreate8`), XINPUT1_3 `#2`/`#3` (`XInputGetState`/`XInputSetState`, to GameController.framework),
     DINPUT8 `DirectInput8Create` (keyboard and mouse devices).
   - USER32 (7), SHELL32 (3: `SHGetFolderPathA` → My Documents), COMCTL32 (3), WINMM `mmio*` (7, RIFF/WAV reading),
     ole32 `CoFreeUnusedLibraries`, d3d9 `D3DPERF_SetOptions`.
   - GalaxyWrp.dll (11 `SteamAPI_*` shims): stub as "no Steam/Galaxy" (`SteamAPI_Init` returns false).
   - libvorbisfile (6 `ov_*`): implement natively on the host's libvorbisfile, or stb_vorbis.
   - d3dx9_38 (25): matrix/vector/plane maths (easy), `D3DXCreate*TextureFromFileInMemory` (DS2 has the
     non-`_38` ones), `D3DXGetShaderConstantTable`, `D3DXAssembleShader`/`D3DXCompileShader` (see whether the game
     calls them in normal play; Gamebryo usually loads the precompiled `.sdp` shaders).
3. **Programmable shaders on Metal.** DS2's `d3d9.c` stores `CreateVertexShader`/`CreatePixelShader` bytecode but
   never runs it, because DS2 draws fixed-function plus HLSL effects. FNV draws almost everything with SM 2/3
   bytecode. Plan: MojoShader (zlib) with the centroid patch at create time → MSL → `MTLLibrary`. Then bind
   `SetVertexShaderConstantF`/`PixelShaderConstantF` (already stored in `vsc`/`psc`) as a constant buffer, and map
   MojoShader's attribute and sampler names to the vertex declaration and texture stages. Cache the compiled
   libraries by bytecode hash. `PARTICLE.vso` needs MojoShader's relative-addressing fix or a hand port.
4. **Render targets.** FNV renders to several targets (HDR, depth, shadow maps, water reflections, MRT). DS2's
   `SetRenderTarget` handles index 0 only.
5. **CPU identity.** `rt_cpuid` reports a family-5 Pentium without MMX/SSE (what DS2 expects). Set `rt_cpuid_sse2 = 1`
   in the FNV profile so the C runtime and engine see an SSE2 CPU. FNV's code uses SSE unconditionally anyway.
6. **Threads.** FNV runs real worker threads (IO, AI linear tasks, Havok). The runtime already runs guest threads
   natively. `lock`-prefixed ops become atomics or the runtime bus lock, and `xchg` with memory is an atomic swap
   (fixed for FNV; DS2 emitted a plain read and write). The two mechanisms do not exclude each other.
   arm64 atomics fault on unaligned addresses where x86 locked ops don't: watch for SIGBUS at a locked instruction.
   Look for races the x86 memory model hid; arm64 is weakly ordered.
7. **C++ exceptions / SEH.** 6,500 functions install C++ EH frames (destructors on unwind). Only 5 are `__try`
   blocks, all in the C runtime, and 4 of those use `_except_handler4`, which `lift.py` doesn't parse yet. If the
   game throws in normal play, catch continuations are needed (DS2 PLAN item 4).

## Floating-point notes for the Mac

- The generated code must keep `-ffp-contract=off`: an arm64 fused multiply-add changes results.
- `rt_fpcr_sync` puts the host rounding mode under the **x87** control word. SSE has its own (MXCSR). If FNV ever
  runs the x87 in a directed rounding mode while SSE code runs, SSE results would round the wrong way on arm64.
  Watch for `fldcw`/`ldmxcsr` with non-default rounding.
- A NaN created from non-NaN inputs is `0x7fc00000` on arm64 and `0xffc00000` on x86. Bit-tests on NaNs are rare.
- `rcpps`/`rsqrtps`/`rsqrtss` return exact results, not the hardware's 12-bit approximations.

## Tests

```sh
recomp/.venv/bin/python recomp/tests/fuzz_sse.py recomp/work/fnv/FalloutNV.exe recomp/work/fnv/analysis.json build
recomp/.venv/bin/python recomp/tests/fuzz_sse.py recomp/work/fnv/FalloutNV.exe recomp/work/fnv/analysis.json run 60
FUZZ_EXE=recomp/work/fnv/FalloutNV.exe FUZZ_ANALYSIS=recomp/work/fnv/analysis.json recomp/.venv/bin/python recomp/tests/fuzz_insn.py build
FUZZ_EXE=... FUZZ_ANALYSIS=... recomp/.venv/bin/python recomp/tests/fuzz_insn.py run 20
# shaders: build MojoShader (git ad5dff8) with tools/mojoshader-metal-centroid.patch, then
cc -I mojoshader recomp/tools/sdp2msl.c libmojoshader.a -lm -o sdp2msl && ./sdp2msl out/ "<game>/Data/Shaders/"*.sdp
for f in out/*.metal; do xcrun -sdk macosx metal -c "$f" -o /dev/null || echo "$f"; done      # Mac only
```
