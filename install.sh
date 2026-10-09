#!/bin/bash
# install.sh --game-dir <The Sims 2 Legacy Collection folder> [--app-dir DIR] [--data-dir DIR]
# install.sh --nightly                 installs "The Sims 2 Nightly.app" next to the stable app: the newest experimental
#                                      work (the repository's nightly branch, fetched from GitHub and built in
#                                      build/nightly; this checkout is left as it is). It shares the data folder
#                                      (neighbourhoods and settings) with the stable app. Run it again to update.
#
# With no game option, the game folder of an app already installed is used again (reinstall or update).
#
# Builds the natively recompiled The Sims 2 Legacy Collection from your own Steam copy (copy the folder over from a PC,
# or a CrossOver Steam library) and installs "The Sims 2 Native.app" (Metal; no Wine, no Rosetta). The game folder is
# only read: settings, neighbourhoods and logs go to the data folder (default ~/Games/Sims2Native). The launch window's
# art comes from the game's Steam store page at install time; nothing from the game is stored in this project. Needs
# the Xcode command line tools and python3 (the recompiler installs capstone with pip into recomp/.venv). The first
# build takes about fifteen minutes, and its analysis about 26 GB of memory.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=""; GOG_EXE=""; APPS="$HOME/Applications"; DATA="$HOME/Games/Sims2Native"
NIGHTLY=""; AS_NIGHTLY=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in --nightly) NIGHTLY=1; shift; continue;; --as-nightly) AS_NIGHTLY=1; shift; continue;; esac
  ARGS+=("$1"); [ $# -gt 1 ] && case "$1" in --*) case "$2" in --*) ;; *) ARGS+=("$2");; esac;; esac
  case "$1" in
    --game-dir) GAME="$2"; shift 2;; --app-dir) APPS="$2"; shift 2;; --data-dir) DATA="$2"; shift 2;;
    *) echo "unknown option $1"; exit 1;;
  esac
done
# the stable app, or (--as-nightly, used by --nightly) the nightly one next to it
APP_NAME="The Sims 2 Native"; APP_SHOWN="The Sims 2"; APP_ID=native; APP_LOG=Sims2Native
[ -n "$AS_NIGHTLY" ] && { APP_NAME="The Sims 2 Nightly"; APP_SHOWN="The Sims 2 Nightly"; APP_ID=nightly; APP_LOG=Sims2Nightly; }
installed_game() {     # the game folder an installed app was set up with (for reinstalls and updates)
  local a L v x; for a in "The Sims 2 Native" "The Sims 2 Nightly"; do
    L="$APPS/$a.app/Contents/MacOS/launcher"; [ -f "$L" ] || continue
    v="$(grep -m1 '^DEF_GAME=' "$L" | cut -d= -f2-)"           # shell-quoted (printf %q)
    if [ -n "$v" ]; then eval "x=$v"; printf '%s\n' "$x"; return 0; fi
  done; return 0
}
# --nightly: fetch the nightly branch into build/nightly and let its own install.sh install the nightly app
if [ -n "$NIGHTLY" ] && [ -z "$AS_NIGHTLY" ]; then
  command -v git >/dev/null || { echo "git is needed for --nightly"; exit 1; }
  W="$HERE/build/nightly"; echo "== fetching the nightly branch"
  git -C "$HERE" fetch -q origin nightly
  git -C "$HERE" worktree prune
  if [ -e "$W/.git" ]; then git -C "$W" checkout -q -f --detach origin/nightly
  else mkdir -p "$HERE/build"; git -C "$HERE" worktree add -q -f --detach "$W" origin/nightly; fi
  echo "== nightly: $(git -C "$W" log -1 --format='%h %s')"
  [ -e "$W/recomp/.venv" ] || [ ! -d "$HERE/recomp/.venv" ] || ln -s "$HERE/recomp/.venv" "$W/recomp/.venv"   # share the tools
  if [ -z "$GAME$GOG_EXE" ]; then G="$(installed_game)"; [ -n "$G" ] && ARGS+=(--game-dir "$G"); fi
  exec "$W/install.sh" --as-nightly ${ARGS[@]+"${ARGS[@]}"}
fi
[ -n "$GAME" ] || GAME="$(installed_game)"
[ -n "$GAME" ] || { echo "usage: install.sh --game-dir <The Sims 2 Legacy Collection folder> (Base, EP1 ... EP9, SP1 ...)"; exit 1; }
GAME="$(cd "$GAME" && pwd)"
for tool in clang python3; do command -v $tool >/dev/null || { echo "$tool is missing: install the Xcode command line tools (xcode-select --install)"; exit 1; }; done
[ "$(uname -m)" = arm64 ] || { echo "the native build is for Apple Silicon Macs"; exit 1; }
EXE="$GAME/EP9/TSBin/Sims2EP9.exe"
[ -f "$EXE" ] || { echo "no EP9/TSBin/Sims2EP9.exe in $GAME"; exit 1; }
[ -d "$GAME/Base" ] && [ -f "$GAME/3314070_install.vdf" ] || { echo "$GAME doesn't look like a whole Steam install (Base, 3314070_install.vdf)"; exit 1; }
echo "== recompiling $EXE (about fifteen minutes the first time)"
"$HERE/recomp/build_sims2.sh" "$GAME"
"$HERE/recomp/tools/build_app.sh" "$HERE/recomp/work/sims2" >/dev/null
echo "== the launch window's art, from the game's Steam store page"
python3 "$HERE/recomp/tools/sims2_art.py" "$DATA/art" || echo "   (no art: the launch window writes the title)"

A="$APPS/$APP_NAME.app"; echo "== installing $A"
mkdir -p "$APPS"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$HERE/recomp/work/sims2/app/Sims2Native" "$HERE/recomp/work/sims2/app/shaders.metal" "$HERE/recomp/work/sims2/app/dsr_snapshot.bin" "$A/Contents/MacOS/"
cp "$HERE/recomp/work/sims2/Sims2EP9.exe" "$A/Contents/Resources/Sims2EP9.exe"   # the unwrapped executable (your copy, this Mac only)
[ -d "$DATA/art" ] && cp -R "$DATA/art" "$A/Contents/Resources/art"
Q_GAME=$(printf '%q' "$GAME"); Q_DATA=$(printf '%q' "$DATA")      # shell-quoted: any folder name is only data
# updates from the launcher: the branch this app follows (main, or nightly for Nightly), the commit it was built from and
# the checkout it was installed from; its updater fetches the branch into a worktree there and rebuilds the app from it
U_BRANCH=main; U_DIR=stable; [ -n "$AS_NIGHTLY" ] && { U_BRANCH=nightly; U_DIR=nightly; }
U_REPO="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"; U_REPO="${U_REPO%/.git}"
U_BUILT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$U_REPO" ] && [ -n "$U_BUILT" ] && git -C "$U_REPO" remote get-url origin >/dev/null 2>&1; then
  cat > "$A/Contents/MacOS/update" <<UPDATE
#!/bin/bash
# $APP_NAME updater (generated by install.sh): "update --check" prints the newest commit of $U_BRANCH on GitHub;
# "update" fetches it into a worktree of the checkout this app was installed from and rebuilds the app from it
set -euo pipefail
REPO=$(printf '%q' "$U_REPO"); BRANCH=$U_BRANCH; W="\$REPO/build/$U_DIR"
export GIT_TERMINAL_PROMPT=0                              # never wait for a password prompt
if [ "\${1:-}" = --check ]; then                          # GitHub's newest, unless this app already has it: a build
  R="\$(git -C "\$REPO" ls-remote origin "refs/heads/\$BRANCH" | cut -f1)"   # from a newer local commit is never offered an older one
  if [ -n "\$R" ] && git -C "\$REPO" merge-base --is-ancestor "\$R" $U_BUILT 2>/dev/null; then echo $U_BUILT; else echo "\$R"; fi
  exit 0
fi
echo "== fetching \$BRANCH from GitHub"
git -C "\$REPO" fetch -q origin "\$BRANCH"
git -C "\$REPO" worktree prune
if [ -e "\$W/.git" ]; then git -C "\$W" checkout -q -f --detach "origin/\$BRANCH"
else mkdir -p "\$REPO/build"; git -C "\$REPO" worktree add -q -f --detach "\$W" "origin/\$BRANCH"; fi
echo "== \$BRANCH: \$(git -C "\$W" log -1 --format='%h %s')"
[ -e "\$W/recomp/.venv" ] || [ ! -d "\$REPO/recomp/.venv" ] || ln -s "\$REPO/recomp/.venv" "\$W/recomp/.venv"   # share the tools
exec "\$W/install.sh"$( [ -n "$AS_NIGHTLY" ] && echo " --as-nightly" )
UPDATE
  chmod +x "$A/Contents/MacOS/update"
fi
cat > "$A/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# $APP_NAME launcher (generated by install.sh)
DEF_GAME=$Q_GAME
DEF_DATA=$Q_DATA
GAME="\${DS_GAME_DIR:-\$DEF_GAME}"; DATA="\${DS_NATIVE_DATA:-\$DEF_DATA}"; DOCS="\$DATA/drive_c/Users/player/Documents"
mkdir -p "\$DOCS"
L="\$DATA/$APP_LOG.log"                                   # keep the log small: previous one as .old
[ -f "\$L" ] && [ "\$(stat -f %z "\$L")" -gt 5000000 ] && mv -f "\$L" "\$DATA/$APP_LOG.old.log"
B="\$(cd "\$(dirname "\$0")" && pwd)"
export DS_LOG_FILE="\$L"                                    # crash reports attach this app's own log
[ -x "\$B/update" ] && export DS_UPDATER="\$B/update" DS_UPDATE_BRANCH=$U_BRANCH DS_BUILT_COMMIT=$U_BUILT   # the launcher's Updates row
exec "\$B/Sims2Native" --exe "\$B/../Resources/Sims2EP9.exe" --game "\$GAME" --data "\$DATA" 2>>"\$L"
LAUNCH
chmod +x "$A/Contents/MacOS/launcher"
# The app's executable is the game itself (macOS recognises a game, and turns on Game Mode, only for a bundle whose
# executable is the program): it reads these settings when opened (the launcher script above is for the terminal)
P="$A/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"; plutil -insert log -string "$APP_LOG" "$P"
plutil -insert exe -string Sims2EP9.exe "$P"; plutil -insert branch -string "$U_BRANCH" "$P"; plutil -insert built -string "$U_BUILT" "$P"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_SHOWN</string>
  <key>CFBundleIdentifier</key><string>io.github.sims-2-macos.$APP_ID</string>
  <key>CFBundleExecutable</key><string>Sims2Native</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.simulation-games</string>
  <key>GCSupportsGameMode</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
I="$(mktemp -d)"
if python3 "$HERE/recomp/tools/extract_icon.py" "$EXE" "$I/ds.ico" 2>/dev/null && sips -s format png "$I/ds.ico" --out "$I/ds.png" >/dev/null 2>&1; then
  sips -z 512 512 "$I/ds.png" --out "$I/ds512.png" >/dev/null
  if [ -n "$AS_NIGHTLY" ] && clang -fobjc-arc -framework AppKit "$HERE/recomp/tools/nightly_icon.m" -o "$I/nightly_icon" 2>/dev/null \
     && "$I/nightly_icon" "$I/ds512.png" "$I/n.png" && sips -z 512 512 "$I/n.png" --out "$I/ds512.png" >/dev/null; then :; fi   # dark tile, NIGHTLY band
  sips -s format icns "$I/ds512.png" --out "$A/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
fi
rm -rf "$I"
codesign --force --deep --sign - "$A" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A" 2>/dev/null || true
echo "== done: $A (data in $DATA)"
