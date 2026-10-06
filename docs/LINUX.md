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

Internet lobby login was also checked with a saved retail key: the native Linux host now calls
`w32_registry_install(data)` before starting the game, matching the Mac host. The initial Linux port omitted that
call, so the launcher saved the key hash but the game could not find its `DoubleHash` registry value. With the
startup call restored, Internet login reached OpenSpy and the party-selection screen. This verifies the key/login
path; joining another machine and cross-platform gameplay still need a paired test.

## Test Lab

Choose your game files in the launcher, then **TEST LAB → Start test game**. The first launch copies your current
single-player saves into `<data>/test-lab/drive_c/`; load one through the game's Single Player menu. Alternatively,
create a new character there. **Prepare hero / unlock skills** makes the screen hero invincible, raises the four
combat skills to 100, attributes to 500, unlocks the installed passive skills and restores life/mana. The lab's
mutations require a loaded single-player world. Normal Play does not enable the scripting bridge.

- **Locations:** search the installed map's starting groups and travel with the party. This includes locations
  in later acts. Wait for streaming to finish and press Escape in the game to skip any story movie. The status
  line shows the hero's current region. Destination scripts can trigger quests/cinematics; reapply invincibility
  if a scene resets it. This is travel within the loaded map, not a Broken World loader or a quest-completion tool.
- **Gear:** give or give-and-equip a concrete item. The details show its equipment slot and source. Inventory space
  and equipment rules still apply; verify the appearance in-game. Base/developer definitions are hidden by default.
- **Enemies / other objects:** spawn 1–16 nearby. The last spawn becomes the cast target. Invincible spawns permit
  repeated attacks; Friendly spawn allows friendly-target tests. Enemies run their own AI, including their attacks.
- **Spells / power templates:** cast with automatic, self, last-target or ground targeting. Mana is refilled before
  each request. **Trigger effect** calls the game's magic implementation directly, without the caster animation;
  **Animated cast job** instead queues the normal movement/animation job, which can be interrupted or fail after
  submission. Use **Wound hero** before healing tests. **Target party member…** selects an existing companion;
  **Kill test target** then permits resurrection tests. Existing party targets are never included in cleanup.
- **Active powers:** selects, recharges and queues the real power action. Read its required stances in the details
  and equip an appropriate weapon. Some powers enhance the next attack. Their spell templates are also listed
  separately for direct effect tests, which do not exercise the full power animation/stance path.
- **Cast filtered spells in sequence:** runs the visible concrete spell templates at the selected interval and
  stops on a rejected request. Stop cancels future requests, not effects already running. Different target types,
  inventory limits, summon/buff limits and boss-specific scripts need manual setup. This is not a claim that every
  template can be cast by a human hero in an arbitrary scene.
- **Clean up test objects:** removes objects/items created through the panel, including equipped test gear.
  It does not undo quests, buffs, spell-created summons or all indirect effects; reload a fresh save copy for a
  clean scene. Tracking is bounded to 512 direct spawns per run/cleanup. **Refresh save copies** is available while
  the test game is stopped and backs up previous test saves under `test-lab/save-backups/`.

The base archives currently expose 88 travel points, 450 spell/power templates and 37 active powers. The lists are
read from the selected local archives, including template inheritance, rather than bundled game content. Counts
include abstract and developer entries; some unused retail definitions cannot be instantiated. Effect and shader
tabs are a searchable reference inventory. They are not arbitrary effect launchers or shader-execution telemetry.

Each request and response is written to `test-lab/lab/history.jsonl`. A successful response only means the command
ran or a job was queued. Inspect the result in-game, then mark the last test as visually correct or a problem, with
notes. **Export report** includes the local catalog, history and manual reviews. A separate `frames-*.csv` measures
each test session's frame timing (the host writes it on exit); `game.log` contains the latest run's engine output.
Reports/catalogs contain descriptions read from your game files and should remain local. No original game files,
personal saves, normal launcher settings or stored multiplayer keys are modified by these controls.

The native bridge registers small FuBi functions before engine startup and executes Skrit requests from the main
game thread's message pump. It is opt-in (`DS_TEST_LAB=1`) and uses the supported GOG 2.3 export layout. There is no
network control listener. Command delivery is atomic, only one request is pending, and an unanswered mutation is
reported as unconfirmed instead of automatically retried.

Local checks exercised equipment changes, enemy spawning, invincibility, travel to Kalrathia, fire/ice/lightning/
death casts, summoning, healing, power activation and cleanup. Black patches were visible around some effects in
the current fixed-function renderer. These are recorded as visual failures, not coverage passes: the Linux
programmable-effects backend remains outstanding. Synthetic archive, parser and mailbox tests run in Linux CI.
