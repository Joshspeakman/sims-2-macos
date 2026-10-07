# Broken World on Linux

Experimental preview on the `broken-world` branch. This is a separate recompilation of
the expansion engine; loading its archives into the base-game executable is not
sufficient. The original Steam/game directory is never patched.

## Input and build

The currently mapped input is Broken World 2.30.0.4277, SHA-256
`5e82a52aac1bc23bd174bf837a7181af7a7d84dcc76aae7c27ab4bb08df37ba7`.
Other expansion executables need their own verified layouts.

```sh
./recomp/build.sh '/path/to/Broken World/DungeonSiege2.exe' recomp/work/broken-world
```

The build resolves the input's dispatch wrappers into a local executable copy
before lifting it. It also decrypts 21 functions that the original executable
rewrites on first use; compiling their encrypted entry stubs would repeatedly
re-enter decryption. Two CPU states must give identical code, dispatch targets and
initializer bytes while preserving registers, flags and stack. Unknown layouts
or unexpected writes stop preparation. The generated code, executable copy and
provenance manifest remain local under the ignored build directory. Unicorn is
used during preparation and testing only; gameplay uses compiled native code.

Some functions remain virtualized in this executable. Their original x86
handlers are also compiled into native C. Guest calls and continuations use a
flat dispatcher with an address hash, including transitions to the recompiled
audio DLLs. No runtime CPU emulator is added.

The executable also generates short synchronization routines at runtime. The
native bridge recognizes their exact acquire/release instruction templates,
including their variable context offsets, atomic byte operations and saved
register/flag restoration. Unrecognized generated code fails explicitly.

Before compiling, a small synthetic check verifies that byte-register updates
preserve the upper bytes in subsequent stores. The locally installed Clang
23.1.1 fails that check with optimized register coalescing; the build tests and
applies `-mllvm -join-liveintervals=false` when necessary. A compiler that fails
both checks stops the build. This workaround also applies to base-game builds.

The runtime has separate addresses for expansion lighting, matrix transforms,
view distance and the Skrit Test Lab. Its dispatcher follows the expansion's
relocated calls and returns. Base-game builds retain their existing call path.

## Assets, launcher and saves

An expansion asset view includes the eight base resource archives, six expansion
resource archives, `World.ds2map`, `xDS2World.ds2map` and `xDS2XWorld.ds2map`.
It uses symlinks and excludes unrelated mods. The base-game profile continues to
use its own executable and base assets.
When present, the expansion's `presaves` folder is also exposed so its bundled
level-39 heroes appear in character selection. A new level-1 character still
needs to complete the base campaign before entering Broken World, as in the
original game.

The installer can add an expansion build alongside the existing GOG/Steam-base
profiles:

```sh
python3 recomp/tools/install_linux.py \
  --game-dir '/path/to/GOG Dungeon Siege 2' --use-build recomp/work/gog \
  --steam-data '/path/to/Steam Dungeon Siege 2' \
  --broken-world '/path/to/Broken World' --broken-world-build recomp/work/broken-world
```

Selecting Broken World switches both the native executable and asset folder.
Reopen an already-running launcher after installing, then select **Game Files →
Broken World**. The base-game profiles remain available.
It retains the launcher's display, frame-rate and view-distance controls. The
expansion uses `Documents/My Games/Dungeon Siege 2 Broken World`, separate from
base-game saves. Its Test Lab uses `test-lab-broken-world` and copies expansion
saves instead of modifying the normal save folder.

Use **Convert Hero** to copy an existing base character into the expansion's
save folder. The original expansion checksum list omits `0xd4ee4a9f`, the content
CRC written by the supported GOG base profile, which silently hides those heroes.
The native expansion accepts that additional CRC; other CRCs follow the original
checks, and save version/format validation still runs. This does not enable
arbitrary modded saves or replace the requirement to complete the base campaign
before taking that hero into the expansion campaign. The bundled level-39 heroes
can enter the expansion immediately.

## Validation

Synthetic checks cover profile routing, archive selection, save isolation,
relocated calls, return-based branches, import continuations, atomic operations
and generated lock acquire/release behavior. A local
100-case comparison of the recompiled expansion matrix transform matched the
original x86 registers and writable memory. The rebuilt base game loads an
existing test save into its opening campaign area; the Linux renderer,
frame-pacer and network checks also pass.

The expansion reaches its main menu, character creation, premade-hero selection,
campaign selection and difficulty selection. Local gameplay checks loaded the
Dryad Outpost with the bundled Hadrian hero, exercised character movement and
Test Lab status/invincibility, and wrote party/radar saves. A separate process
reloaded that save at 3440×1440 with the 244 FPS cap and VSync disabled. This
confirms the selected cap and resolution, not a sustained 244 FPS performance
claim. The installed build also reloaded the outpost and returned to the main
menu. A GOG base test hero appeared in Convert Hero after the checksum fix,
was copied into the separate expansion folder, and loaded its original campaign
in the expansion engine (`a0_01_01_tutbeach`). Saving then wrote expansion format
63 with the expansion content CRC. Hash checks confirmed the original
base save files were unchanged. All checks used isolated test data, not personal
saves.

Known limits:

- Transparent effects can produce large black polygons, also seen in the base
  Linux port's fixed-function renderer. The Mac programmable-effects backend
  has not been ported to Linux.
- Startup and world loading remain slow with this executable profile.
- Later campaign areas, uncommon exception paths, movie/audio coverage and
  real multiplayer hosting/joining need further validation. Loopback network
  tests are not a cross-platform multiplayer test.
