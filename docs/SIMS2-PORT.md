# The Sims 2 Legacy Collection: native port with the Fallout NV / Dungeon Siege II recompiler

This repository forks [fallout-nv-macos](https://github.com/Joshspeakman/fallout-nv-macos) at its `metal` branch
(`8bf8599`, the branch where FNV runs on the Mac: MojoShader → Metal, arm64 memory ordering, the Mac app and
`install.sh`). It points the static recompiler (x86 → C → clang) at the player's own **Steam** copy of
**The Sims 2 Legacy Collection** (app 3314070). As with the other ports, nothing from the game is committed. All
generated code goes under `recomp/work/`, which git ignores, and the game folder is only read.

The whole collection (base game, 8 expansions, 6 stuff packs) runs from a single executable, `EP9/TSBin/Sims2EP9.exe`.
The other folders (`Base`, `EP1`…`EP9`, `SP1`…`SP7`) hold only data.

| File | sha256 |
|---|---|
| `EP9/TSBin/Sims2EP9.exe` as Steam ships it (2026-10-07) | `24041f834e979cc088714713c3207540ff9093f51ff126450a4f7989432156b6` |
| the same, unwrapped by `tools/steamstub.py` | `7aaf7336249c05c31270416e5abeb5b438f0dc9e6af9d59ff34c6342a5abd9cc` |
| `EP9/TSBin/ijl15.dll` (Intel JPEG Library) | `41d37bfb0a39017497e0aa373dc01f71ac9c5046c75f7cd269bee52112a5f3a1` |

EA is still patching this collection, so `build_sims2.sh` refuses any other `Sims2EP9.exe`. `SIMS2_ANY_BUILD=1`
tries anyway. Once there are hooks at fixed addresses, a new build means a new analysis.

## Status (2026-10-07, done on Linux x86-64)

| Step | State |
|---|---|
| Steam DRM (`tools/steamstub.py`) | **new**. `Sims2EP9.exe` is wrapped in SteamStub 3.1 (x86). Its `.text` is AES-256-CBC encrypted (entropy 8.0) and the entry point sits in `.bind`. The tool decrypts `.text` in place and restores the original entry point (`0xa08248a3`, MSVC's `__security_init_cookie` + `__tmainCRTStartup`). Every section keeps its RVA and file offset. AES uses the `cryptography` module if present, otherwise the system `openssl`, so the Mac needs nothing extra. Check: all **145,357** base relocations inside `.text` hold an address inside the image after decryption (on the encrypted file, 144,746 of them don't) |
| Analysis (`tools/analyze.py`) | **109,632 functions, 97.3% of `.text`** (5.8 M instructions). 1,473 jump tables resolved, 190 unresolved (62 bounded heuristically while lifting). 4.5 min, about 26 GB of RAM at its peak |
| Lifting (`tools/lift.py --game sims2`) | all 109,632 functions lifted, **0 internal errors**, 4.9 min. Unsupported: only code that never runs (see below) |
| `ijl15.dll` | 1,736 functions, 0 internal errors. Every import is already implemented. Base 0x60000000 is free, so it's lifted as is |
| Compiling the generated C | **all 281 files compile** (exe + `ijl15.dll`, 111,368 functions), 0 errors, 589 MB of C, 2 min on 16 jobs (26 CPU-minutes). `build_sims2.sh` end to end, from the Steam folder: 7.5 min on 24 cores |
| SIMD lifter on Sims 2's instruction forms (`tests/fuzz_sse.py`) | exe: 289 forms / 680 instances × 60 runs, **0 mismatches** with Unicorn. `ijl15.dll`: 97 forms / 282 instances × 60 runs, 0 mismatches. **Bug found and fixed**: MMX `packsswb`/`packssdw`/`packuswb` used the XMM layout, so the source operand's half was dropped (FNV never used the MMX forms). **Added**: `pshufw` (66 sites in `ijl15.dll`) and `cvtpi2ps` (13 in the exe) |
| Integer/x87 lifter (`tests/fuzz_insn.py`) | 6,128 forms / 18,114 instances × 20 runs. Outside SIMD rows (this fuzzer does not seed XMM/MMX state; `fuzz_sse.py` covers those), only the expected differences remain: x87 transcendentals (`fyl2x`, `f2xm1`, `fprem`/`fprem1`: last-bit differences from the double model; one `fprem1` site lands one modulus apart in 2 of 20 runs, a quotient rounded at the half-way point) and `cpuid` (the fixed fake CPU) |
| Linking / running (Linux, SDL/OpenGL host) | **runs to the main menu**: Steam check (offline shim), intro movies (EA MAD, decoded by the game), loading screen, the neighbourhood chooser with its 3D Sims. See "Running" below |

Build the C (Mac or Linux):

The analysis peaks at about 26 GB of memory (`analyze.py` caches a decoded instruction per address). That is tight on
a 32 GB Mac. If it swaps, run the analysis on a bigger machine, or bound that cache.

```sh
recomp/build_sims2.sh "/path/to/steamapps/common/The Sims 2 Legacy Collection"     # -> recomp/work/sims2/
```

### Unsupported instructions, and why they don't matter

The executable was rebuilt in 2025 with a current MSVC and keeps several CPU-specific paths, each chosen by `cpuid`:

- **3DNow!** (`pfmul`, `pfadd`, `femms`, … about 2,700 sites): the AMD paths of the statically linked D3DX.
- **AVX / AVX2 / AVX-512, SSE4.1, SSSE3** (`vmovdqu`, `vpshufb`, `pmulld`, `pcmpistri`, `palignr`, …): the CRT's
  `memcpy`/`strlen`/`memset` dispatch on `__isa_available`, plus a few math routines.
- `in`/`out`/`hlt`/segment registers/`enter` nesting (about 330): data decoded as code.

`rt_cpuid` with `rt_cpuid_sse2 = 1` reports a family 6 Intel CPU with SSE2 and nothing newer. Its highest basic leaf
is 1, so leaf 7 (AVX2) is never queried, and an extended-leaf query returns a value below 0x80000001, so there's no
3DNow!. Every one of these paths is therefore dead code. The lifter emits a trap there, so if one ever does run, it
names itself.

## What the executable needs (survey)

- **Steam.** If `SteamInternal_SteamAPI_Init` fails, the game shows "Steam Initialization Failed. The game failed to
  successfully launch from steam." and exits (`0xa0c2ba85`). On success it immediately calls
  `SteamInternal_ContextInit` and then `ISteamUser::GetSteamID` through a vtable (`0xa0c2b91d`). So `steam_api.dll`
  (8 imports) needs an *offline* shim that returns success and hands out small fake interface objects (ISteamUser,
  and whatever else `SteamInternal_FindOrCreateUserInterface` is asked for), built the way `d3d9.c` builds guest
  vtables. FNV's `galaxywrp` stubs (`SteamAPI_Init` → 0) are not enough here.
- **Shaders.** There's no `d3dx9_*.dll` import: D3DX, including its effect framework and the HLSL/asm shader
  compiler, is linked statically and gets lifted with the game. The game compiles its own shader text at run time
  and calls `CreateVertexShader`/`CreatePixelShader` with the bytecode, which is exactly the metal branch's
  MojoShader → MSL path. `vs_1_1`…`vs_3_0` and `ps_1_1`…`ps_3_0` all appear. Expect compile-time cost at start-up
  (lifted compiler), and cache by bytecode hash as FNV does.
- **Movies** are EA MAD (`MADk`, 412 `.movie` files), decoded inside the executable. No Bink, no external codec.
  `vp6vfw.dll` + `MSVFW32`/`AVIFIL32` are only the in-game **video capture** (`ICSeqCompressFrame`,
  `AVIStreamWrite`), so they can be stubs that report "no compressor".
- **Data folders.** Steam's `3314070_install.vdf` writes, for every pack,
  `HKCU\Software\Electronic Arts\The Sims 2 Ultimate Collection 25\Sims2<EP|SP>n.exe` with `path` =
  `<install>\<folder>` and `Installed` = 1 (`Sims2EP9.exe` → `Base`), plus the `EPsInstalled` list and `DisplayName`
  per language under the parent key. The executable reads the same key (`Software\Electronic Arts\The Sims 2
  Ultimate Collection 25\`, `ep%ddir`, `TSData`). The runtime's registry should be filled in from that `.vdf` at
  start-up rather than hand-written.
- **User folder**: `Documents\EA Games\The Sims 2 Legacy` (neighborhoods, downloads, `Config`, `Logs`, thumbnails).
- **Telemetry**: WININET posts a `boot_start` event (`"storefront" : "steam"`); `crashpad_handler.exe` is the crash
  reporter. Both get stubbed (no network, no child process).
- **Large-address aware** (characteristics `0x122`) with the image at 0xA0000000. Guest memory is one 4 GB region,
  so the address itself is fine, but anything in the runtime that assumes guest pointers < 0x80000000 (signed
  comparisons, the heap's top-down placement) needs checking.

## Running (Linux, 2026-10-07)

![Main menu](screenshots/sims2-main-menu.jpg)

```sh
recomp/build_sims2.sh "<…>/The Sims 2 Legacy Collection"          # recompile (incremental) and link
SECS=150 recomp/tools/sims2_iterate.sh run                            # a windowed test session; log in recomp/work/run-*.log
DS_SHOT_RAW=1 DS_SCRIPT="@140:shot:/path/menu.png" SECS=150 recomp/tools/sims2_iterate.sh run   # screenshots
```

What it took, beyond the imports (all 438 are implemented):

- **Profile** (`SIMS2_EDITION`, `runtime/edition.h`): the exe at `EP9\TSBin` below the collection folder, the
  working folder there, registry from Steam's `3314070_install.vdf` (`w32_sims2_registry`), SSE2 CPU,
  shader-model-3 caps (`MODERN_EDITION`, shared with Fallout NV).
- **Offline Steam** (`sims2_imports.c`): `SteamAPI_Init` succeeds; ISteamApps008 `GetCurrentGameLanguage` and
  ISteamUser023 `GetSteamID` are the only methods the game calls.
- **Crash reporter** (crashpad, linked in): its setup `0xa0c2b206` is overridden to return (`SIMS2_OVERRIDES` in
  `lift.py`, `hooks.c`).
- **Lifter**: 16-bit `push`/`pop`/`pushf` (a Cyrix CPU check), reading segment registers (the CRT's fatal-error
  path), MMX `pack*` fixed, `pshufw`/`cvtpi2ps`.
- **PEB.ProcessParameters**: the newer CRT reads it in every thread.
- **Direct3D 9**: `Get/SetSoftwareVertexProcessing` keep the mode (the game keeps one caps copy per mode); a reused
  device takes the new behaviour flags; a windowed 0x0 back buffer is the window's client size; **a vertex shader
  without a pixel shader runs Direct3D's fixed-function texture stages** (`FF_PS`, `FF_MSL_PS` in
  `d3d9_shader.c`), which is how the game draws its UI, movies and much more.
- **Windows**: the game's `multimon.h` needs every monitor function by `GetProcAddress` (else an uninitialised rect
  places the window off-screen); `SystemParametersInfoA` answers unknown queries with 0.
- **Files**: the game opens every package for writing. Such files are now read where they are and copied into the
  data folder's overlay only on the first write (`File.cow`, `files.c`); before, 8.5 GB of packages were copied.

## Next

1. **Interaction**: click into a neighbourhood, Create-a-Sim, live mode. Input is untested (the host's DS_SCRIPT
   clicks work for other ports); expect new imports and D3D paths (render targets for reflections and shadows,
   the neighbourhood view).
2. **The Mac**: nothing has been built there yet. `install.sh`, the launch window and `build_app.sh` still make
   Fallout NV; the Metal side of the fixed-function stages (`FF_MSL_PS`) is written but has never been compiled.
   `analyze.py` peaks at about 26 GB of memory (tight on a 32 GB Mac).
3. **C++ catch continuations**: a `throw` that the game catches can't resume yet (`lift.py` registers `__except`
   blocks only). None was needed to reach the menu. A known case: with a data folder left by earlier broken runs
   (kept as `~/.local/share/sims2-linux-badstate`), a curve property reaches its parser empty, and
   `std::length_error` ("vector too long") ends the game about a minute in. It would on Windows too, so the bad
   state, not the catch, is the bug: find what wrote it.
4. **Audio**: test sessions mute it (`W32_AUDIO_MUTE`); not checked yet.
5. **Build**: the lift is not deterministic between some runs (every C file was rebuilt after small `lift.py`
   changes, with `PYTHONHASHSEED=0` set), which costs about 5 minutes per lifter change. Diff
   `work/sims2/prev/lift_000.c` against the new one before the next lifter change to find the cause.

## Tests

```sh
recomp/.venv/bin/python recomp/tests/fuzz_sse.py recomp/work/sims2/Sims2EP9.exe recomp/work/sims2/analysis.json build
recomp/.venv/bin/python recomp/tests/fuzz_sse.py recomp/work/sims2/Sims2EP9.exe recomp/work/sims2/analysis.json run 60
FUZZ_EXE=recomp/work/sims2/Sims2EP9.exe FUZZ_ANALYSIS=recomp/work/sims2/analysis.json recomp/.venv/bin/python recomp/tests/fuzz_insn.py build
FUZZ_EXE=... FUZZ_ANALYSIS=... recomp/.venv/bin/python recomp/tests/fuzz_insn.py run 20
python3 recomp/tools/import_gap.py recomp/work/sims2/Sims2EP9.exe
```

`fuzz_insn.py` now skips instances whose absolute memory operand falls in the guest NULL page. Those are data decoded
as code, such as `add byte ptr [0xa001], cl`: they segfaulted the native test library, and they would fault on
Windows too.
