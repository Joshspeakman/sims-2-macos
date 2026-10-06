# Linux bring-up and edition compatibility

The Linux branch starts at macOS `3e3e47c`. Preserve the upstream DS2-specific lifter hooks, native vertex/lighting
loops, C++ archive exception handling, Windows timers, D3D9 texture conversion, and lobby/networking behavior.
Platform replacements are limited to services provided by the host OS. Disable fused multiply-add when compiling
lifted code and native hot loops, and synchronize the x87 rounding mode on Linux as on arm64.

## Executable profiles

| Input observed locally | SHA-256 | Status |
|---|---|---|
| GOG 2.3, installer 37617 | `c17e1cc9e01b5d2439a92e06b905040379ad4bb8618b822582c46f5fa29db4e2` | Native compilation supported |
| Modified 2.3 executable in the Steam/Broken World installation | `5e82a52aac1bc23bd174bf837a7181af7a7d84dcc76aae7c27ab4bb08df37ba7` | Different layout; rejected by the recompiler |

The second executable was also found in a local Broken World fix package. This is not a verified pristine Steam
executable, so its checksum must not be treated as a canonical Steam release identifier. Its entry is `0xa45e80`,
versus GOG's `0xa2b818`, and known hot-loop/hook addresses contain different instructions. Simply accepting its hash
would apply patches to unrelated code. A proper port needs independent analysis, address identification, validation
of overrides, and per-edition build outputs. Do not patch a live Steam installation to make a build pass.

The eight base `Resources/*.ds2res` archives and `Maps/World.ds2map` in the tested Steam folder are byte-identical
to the GOG copies. Its five Miles/Bink binaries also match. Loading the mixed base/expansion folder with the GOG
runtime fails during startup. Loading a view containing just the base resources and world reaches the menu.
`recomp/tools/steam_data_view.py` constructs that view using links, without moving or modifying originals.
The native code in both cases is still compiled from GOG. Broken World requires its own port and is not a supported
content mode in this preview.

## Platform work

- Monotonic timing, Linux host page size, Linux x86-64 exception contexts and ELF crash backtraces.
- Native SDL audio sinks for DirectSound, waveOut and Miles; recompiled Miles providers and Bink retained.
- FreeType/fontconfig implementation of the existing GDI text interface.
- SDL window, keyboard, absolute DS2 virtual cursor, high-polling mouse-event coalescing, and message timers.
- Futex notification of render commands/presentation and one presentation clock, including unlimited/custom FPS.
- OpenGL fixed-function command consumer with UNORM blending and one gamma application; D3D9 depth/stencil,
  viewport-clipped clear rectangles and readback failure acknowledgement.
- Explicit WinSock → POSIX socket option, linger, timeout and error conversion. Shared DS1 transport fixes for
  retransmission, delayed ACK timing and orderly close, without changing the DirectPlay wire format.

## Remaining validation

Synthetic renderer and loopback tests do not prove complete gameplay or cross-platform multiplayer. Follow up with
campaign traversal, saving/reloading, audio capture, long sessions, Linux/Mac/Windows pairing and packet-loss tests
in an actual world. The Mac effects compiler emits Metal; a GLSL backend and program command consumer are still
needed before enabling `DS2_SHADERS` on Linux. Keep that capability disabled until effects are implemented.

Original shadow rendering remains in place; DS1's Linux-only experimental shadow/DLSS features are not transferred.

## Initial game-driven checks (2026-10-06)

On CachyOS with an NVIDIA RTX 3080 Ti: the GOG-derived x86-64 build reached menus, created a test hero, played the
opening Bink movies, loaded the first campaign area at 1024×768 and saved the test party/radar. A separate run with
Steam base-game data read that save and entered the world at 3440×1440 with a 144 FPS limit. SDL's output tap produced
44.1 kHz stereo PCM with a nonzero waveform. This is a startup/campaign smoke test, not a full playthrough or audio
fidelity comparison. Test saves and media remain local in ignored directories.
