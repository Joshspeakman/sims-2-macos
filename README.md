# The Sims 2 for Apple Silicon Macs

The Sims 2 Legacy Collection (Steam), statically recompiled from your own copy into native arm64 code and run on
Metal. No Wine, no Rosetta, no emulator.

The game installation is not supplied. `install.sh` reads your Steam copy, recompiles its executable on your
Mac, and builds an app that reads the game's data from your folder. The game folder is only read; nothing is written
into it.

The recompiler and Windows runtime come from the author's earlier ports
([dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos), then Dungeon Siege II and Fallout: New
Vegas); the Direct3D 9 to Metal renderer comes from the Fallout: New Vegas port.

![Main menu](docs/screenshots/sims2-main-menu.jpg)
![Desiderata Valley](docs/screenshots/sims2-neighborhood.jpg)

## Status

**Playable, early (2026-10-10).** The code on `main` and `nightly` is currently the same; there is no tagged release yet.

On an M1 Pro: the intro, the neighbourhoods in 3D, families' lots in live mode with their Sims, Create-a-Sim, build
and buy mode, saving and loading, music and sounds, and every expansion and stuff pack in the collection (they all run
from the one executable). It runs at the display's resolution, in full screen or a window, with a launch window for
the display, the game's graphics options and the camera. A 15-minute session at speed 3 and a 26-minute session on an
installed build ran without faults. Multi-hour sessions haven't been tested. See [Known issues](#known-issues).

The work log, what has been checked and how: [docs/SIMS2-PORT.md](docs/SIMS2-PORT.md).

## What you need

- **A Mac with Apple Silicon** (M1 or later). `install.sh` stops on an Intel Mac.
- **macOS 13 or later** (the app's minimum). Development and testing were done on a recent macOS beta; older
  versions haven't been tried. [Game Mode](https://support.apple.com/en-us/105118) needs macOS 14 or later.
- **Memory:** the [development notes](docs/SIMS2-PORT.md) report an analysis peak of about 26 GB of RAM
  for the game's roughly 110,000 functions; this is an observation, not a measured minimum for every Mac.
  On a 32 GB Mac that is tight; with less, expect heavy swapping or a failed build. See [Building with less memory](#building-with-less-memory).
- **The Xcode command line tools**: `xcode-select --install`. They provide clang, git and python3.
- **An internet connection while installing**: the build installs two Python packages (Capstone, Unicorn) into
  `recomp/.venv`, and the launch window's artwork is downloaded from the game's Steam store page.
- Build time and peak disk use have not been verified for a clean install. Allow room for your game files,
  generated source and object files, the app, and additional update worktrees; time varies with the Mac. Later builds
  can reuse the analysis and unchanged compiled files (see below).
- **Your own copy of The Sims 2 Legacy Collection from Steam**, exactly the build below.

### The supported game build

Only the Steam release is supported: **Steam app 3314070**, with `EP9/TSBin/Sims2EP9.exe` as Steam shipped it on
2026-10-07:

```
SHA-256 24041f834e979cc088714713c3207540ff9093f51ff126450a4f7989432156b6  EP9/TSBin/Sims2EP9.exe
```

The build checks this hash and refuses any other executable (another store, a disc version, or a newer Steam update).
EA is still patching the collection. If Steam updates the game, the build stops with "not the build this port was made
from" until the port is updated for it. `SIMS2_ANY_BUILD=1` skips the check, but a different executable is unlikely
to work: the port patches code at fixed addresses.

`install.sh` also needs the **whole** Steam install folder: `Base`, `EP1` to `EP9`, `SP1` and up, and
`3314070_install.vdf` (Steam's install script; the app builds the game's registry entries from it).

### Getting the Windows game files onto your Mac

Use a complete Windows installation of the Legacy Collection. Either:

- **Copy it from a Windows PC:** install the game with Steam on the PC and copy the whole folder
  `steamapps/common/The Sims 2 Legacy Collection` to the Mac, for example to
  `~/Games/The Sims 2 Legacy Collection`.
- **Use a CrossOver or Whisky Steam library:** point `--game-dir` at
  `.../drive_c/Program Files (x86)/Steam/steamapps/common/The Sims 2 Legacy Collection` inside the bottle.

`install.sh` for The Sims 2 has no SteamCMD option. Downloading the Windows depot yourself with SteamCMD
(`+@sSteamCmdForcePlatformType windows ... +app_update 3314070`) is untested. The folder must still contain
`3314070_install.vdf`. Valve's [macOS SteamCMD download](https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz),
inspected on 2026-10-10, contains an Intel (`x86_64`) executable and needs
[Rosetta](https://support.apple.com/en-us/102527) on Apple Silicon. The recompiled game runs natively.

### About the Steam wrapper

Steam ships `Sims2EP9.exe` wrapped in SteamStub (its code is encrypted). To recompile it, the build removes the wrapper
from a **copy** in the build folder (`recomp/work/sims2/`, git-ignored), using `recomp/tools/steamstub.py`, and checks
the result against a second known hash. Your game folder is not modified. This is only for recompiling a copy you
bought. The installed app contains that unwrapped copy, so it is for your own Mac: don't share it.

## Install

Keep the clone in a path without spaces: the current compile scripts split source paths on whitespace.

```sh
xcode-select --install                     # once, if you don't have the command line tools
git clone https://github.com/Joshspeakman/sims-2-macos.git
cd sims-2-macos
./install.sh --game-dir "/path/to/The Sims 2 Legacy Collection"
```

This recompiles the game and installs **The Sims 2 Native** in `~/Applications` (it shows as "The Sims 2"). Open it
from there or from Launchpad.

**Keep the clone.** The app's Updates button rebuilds from it (see [Updating](#updating)), and the build folder
inside it holds the cached analysis, whose reported memory cost is described above.

### install.sh options

| Option | What it does |
|---|---|
| `--game-dir DIR` | The Sims 2 Legacy Collection folder. Without it, the folder an installed app was set up with is used again (a reinstall or update). |
| `--app-dir DIR` | Where the app goes (default `~/Applications`). |
| `--data-dir DIR` | Where settings, neighbourhoods and logs go (default `~/Games/Sims2Native`). |
| `--nightly` | Installs **The Sims 2 Nightly** next to the stable app, built from the `nightly` branch (experimental work). It fetches that branch from GitHub into `build/nightly` inside the clone and builds from there; your checkout is left as it is. It shares the data folder (neighbourhoods and settings) and the build folder with the stable app. Run it again to update the Nightly app. |

Environment variables for the build: `SIMS2_ANY_BUILD=1` (skip the executable check, see above),
`SIMS2_BUILD_JOBS=n` (parallel compile jobs; default all cores), `SIMS2_REANALYZE=1` (redo the analysis).

### Building with less memory

If you have access to another machine with more memory (the same build script also runs on Linux), use the
**same repository commit and supported executable** there. Run
`recomp/build_sims2.sh "/path/to/The Sims 2 Legacy Collection"`, then privately copy **both**
`recomp/work/sims2/analysis.json` and `recomp/work/sims2/analysis.log` into that directory in your Mac clone.
Do not copy the other machine's compiled objects. Run `touch recomp/work/sims2/analysis.json` on the Mac before
`install.sh`: the script reuses that file if it is at least as new as `recomp/tools/analyze.py`, and also reads
`analysis.log` even when analysis is skipped. This transfer procedure has been checked against the script, but has
not been exercised as a clean install here.

The cache check uses timestamps; it does not compare executable hashes with the cached analysis. Do not reuse
an analysis from a different executable or recompiler revision. Set `SIMS2_REANALYZE=1` when either changes; lowering
`SIMS2_BUILD_JOBS` reduces parallel compilation, not the memory needed for analysis.

## Where things go

| What | Where |
|---|---|
| The app | `~/Applications/The Sims 2 Native.app` (and `The Sims 2 Nightly.app` with `--nightly`) |
| Data folder | `~/Games/Sims2Native` (set with `--data-dir`) |
| Your neighbourhoods, downloads and the game's `Config` | `~/Games/Sims2Native/drive_c/Users/player/Documents/EA Games/The Sims 2 Legacy` |
| Launch window settings | `~/Games/Sims2Native/launcher.plist` |
| Logs | `~/Games/Sims2Native/Sims2Native.log` (Nightly: `Sims2Nightly.log`). Update output is in `update.log`. The game log is cut at about 5 MB: the earlier part goes to `.previous` during a session and to `.old.log` at the next launch. |
| Crash reports | `~/Games/Sims2Native/CrashReports` |
| Shader and texture caches | `~/Library/Caches/io.github.sims-2-macos/` (safe to delete while the game is closed; they are rebuilt) |
| Game packages the game changes | copied into the data folder the first time the game writes to one; the originals stay untouched |
| Build files | `recomp/work/` and `recomp/.venv` inside the clone; `build/` for the updater's and Nightly's worktrees |

The Saves button in the launch window opens the neighbourhoods folder in Finder.

## The launch window

The app opens with a launch window. Your choices are kept for the next launch.

- **Resolution** (top row): Retina (every pixel of the display: the sharpest, and the default on a Retina display),
  the display's size in points (lighter on the GPU), or a common size scaled to fill the screen.
- **Display**
  - **Interface Size**: 100% to 300%. The game is laid out at the resolution divided by this size, while the renderer
    draws at the full resolution, so the interface is larger and the 3D stays sharp. The default is 200% at Retina
    resolution when it fits (the game's layout in points), and 100% otherwise. Sizes that would leave the game under 1024 x 700
    aren't offered.
  - **Window**: Full Screen (macOS full screen, with Game Mode on macOS 14 or later) or a Window you can move and resize.
  - **Notch** (only on displays with one): Below the Notch, or Around the Notch (the whole display in a borderless
    window; no Game Mode).
  - **Frame Rate**: the display's (up to 120 on ProMotion), 60 (offered separately on displays above 60 Hz) or 30 fps.
  - **Intro Movies**: Skip (the default, about 50 seconds sooner) or Play.
- **Graphics** and **Detail**: the game's own options: Material Detail, Object Detail, Shadows, Lighting, Effects,
  Reflections, Snow on Ground, Ceilings, Object Hiding and Opaque Interface. Each starts at **Game's Setting**, which
  leaves the choice made in the game's own Options alone. Any other choice is written into the game's settings
  (`Config/userProps.xml`) each time it starts.
- **Camera**: Edge Scrolling (on/off), Edge Scroll Speed (Fast, twice the game's own speed, is the default; also
  Fastest, Normal and Slow), Idle Camera Drift (off by default: the camera stays where you put it) and Event Cameras.
- **Saves**: opens the neighbourhoods folder in Finder.
- **Updates**: shows whether a newer version is on GitHub, and installs it (below).

Sound and everything else is in the game's own Options.

In the game: pinch on a trackpad, or scroll, to zoom (the game's X and Z keys work too); push the pointer against a
screen edge to scroll, in full screen too.

## Updating

**From the app:** the launch window's **Updates** row asks GitHub for the newest commit of the branch the app follows
(`main` for The Sims 2 Native, `nightly` for The Sims 2 Nightly). Press it to update: it fetches that branch into a
worktree inside the clone you installed from (`build/stable` or `build/nightly`), rebuilds the app from your own game
copy, and reinstalls it. Saves and settings are kept. For this to work, the clone must still be where you installed it
from, and `git` must be able to fetch from GitHub without asking for a password.

**By hand:** `git pull` in the clone, then repeat your install command: `./install.sh` for the stable app or
`./install.sh --nightly` for Nightly (the game folder is reused). Include your original custom folder options.

If you installed with `--app-dir` or `--data-dir`, update by hand with the same options. The Updates button doesn't
pass them on, so it fails or installs with the default folders.

## Uninstall

1. Delete `~/Applications/The Sims 2 Native.app` (and `The Sims 2 Nightly.app`).
2. Delete `~/Library/Caches/io.github.sims-2-macos`.
3. Delete the clone (it holds the build folder).
4. Delete `~/Games/Sims2Native` only if you don't want to keep your neighbourhoods.

Your game folder was never changed.

## Known issues

- **Short pauses when new content appears:** up to about a second when Sims or objects first appear, and several
  seconds while a neighbourhood first loads. This is EA's texture conversion running as recompiled code. Results are
  cached between launches, so it gets better, but it doesn't go away, and a frame-rate cap doesn't remove it.
- **A one-off start-up fault** was seen once in testing and hasn't been reproduced
  ([#2](https://github.com/Joshspeakman/sims-2-macos/issues/2)). If the game closes during start-up, open it again and
  please attach the crash report from `~/Games/Sims2Native/CrashReports` to that issue.
- Multi-hour sessions haven't been tested.
- Music and sounds were checked by recording them; they haven't been listened to closely.
- The game's multisampling (anti-aliasing) isn't supported. Don't force it on in the game's configuration.
- Sim portraits made by earlier builds without hair stay in the save until the household is saved again.
- The coast, a neighbourhood pond and the Create-a-Sim mirror were compared with the original. Other oceans, pools
  and mirrors haven't all been checked.
- Retina resolution costs frame rate. If a lot feels slow, try the display's size in points, or a 60 fps cap.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `Sims2EP9.exe is not the build this port was made from` | Your copy isn't the supported Steam build (see above), or Steam updated the game. |
| `... doesn't look like a whole Steam install (Base, 3314070_install.vdf)` | Copy the whole `The Sims 2 Legacy Collection` folder, not only some of it. |
| `clang is missing` / `python3 is missing` | Run `xcode-select --install`. |
| The build is very slow or is killed during "analysis" | Not enough memory (about 26 GB needed). Close other apps, or see [Building with less memory](#building-with-less-memory). |
| The launch window shows only the title, no artwork | The Steam store page couldn't be reached while installing. Run `./install.sh` again when online. |
| Updates says "Couldn't check" | GitHub couldn't be reached, or `git` needs a sign-in. Update by hand. |
| Updates says "Not available" | The app wasn't installed from a git clone. Reinstall from a clone. |
| Saves says "No saves yet" | The game makes its folder the first time it starts. Press Play first. |
| Something looks wrong after an update | Quit, delete `~/Library/Caches/io.github.sims-2-macos`, and start again. |
| The game crashes | Look in `~/Games/Sims2Native/CrashReports` and the log (see [Where things go](#where-things-go)), and open an issue with them. |

## How it works

`recomp/build_sims2.sh` checks the executable, removes the Steam wrapper from a copy, analyses it (109,632 functions),
translates each x86 function into C, does the same for the game's `ijl15.dll` (Intel JPEG library), and compiles it all
with clang for arm64. That is linked with the runtime: an implementation of the Windows APIs the game uses (an offline
Steam stub, files, registry, threads, windows), Direct3D 9 on the Metal renderer in `src/` (the game's own shaders
translated with MojoShader), DirectSound on Core Audio, and Winsock. The game's threads keep x86 memory ordering on
arm64. Details: [recomp/README.md](recomp/README.md).

The same scripts build on Linux x86-64 (SDL and OpenGL), which is used for development. There it reaches the
neighbourhood; it isn't packaged for players.

## Documentation

- [docs/SIMS2-PORT.md](docs/SIMS2-PORT.md): the port's notes: the executable, what it took, what's been checked on the
  Mac, performance and caches, tests.
- [recomp/README.md](recomp/README.md): the recompiler and runtime, building and testing by hand.
- [NOTICE.md](NOTICE.md): notices and credits.

Other files in `docs/` are carried over from the earlier ports this one grew out of. They don't describe The Sims 2.

## Legal

The Sims and The Sims 2 are trademarks of Electronic Arts Inc. This project is not affiliated with or endorsed by
Electronic Arts or Valve. You need your own complete game installation; the build reads your copy.

The code in this repository is under the MIT license ([LICENSE](LICENSE)).
