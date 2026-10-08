#!/bin/bash
# install.sh --game-dir <Fallout New Vegas folder> [--app-dir DIR] [--data-dir DIR]
# install.sh --gog-installer <setup_fallout_new_vegas_*.exe>   (GOG offline installer; needs: brew install innoextract)
# install.sh --nightly                 installs "Fallout New Vegas Nightly.app" next to the stable app: the newest
#                                      experimental work (the repository's nightly branch, fetched from GitHub and
#                                      built in build/nightly; this checkout is left as it is). It shares the data
#                                      folder (saves and settings) with the stable app. Run it again to update.
#
# With no game option, the game folder of an app already installed is used again (reinstall or update).
#
# Builds the natively recompiled Fallout: New Vegas from your own copy of the GOG release (1.4.0.525) and installs
# "Fallout New Vegas Native.app" (Metal; no Wine, no Rosetta). The game folder is only read: settings, saves and logs
# go to the data folder (default ~/Games/FalloutNVNative). The launch window's art is decoded from your own archives
# at install time; nothing from the game is stored in this project. Needs the Xcode command line tools and python3
# (the recompiler installs capstone with pip into recomp/.venv). The build takes about ten minutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=""; GOG_EXE=""; APPS="$HOME/Applications"; DATA="$HOME/Games/FalloutNVNative"
NIGHTLY=""; AS_NIGHTLY=""; ARGS=()
GOG_SHA=89e7020487e80f20ddc92ea641c4433b2c6839a82f45a076e414d167d11dd0fe          # FalloutNV.exe, GOG 1.4.0.525
while [ $# -gt 0 ]; do
  case "$1" in --nightly) NIGHTLY=1; shift; continue;; --as-nightly) AS_NIGHTLY=1; shift; continue;; esac
  ARGS+=("$1"); [ $# -gt 1 ] && case "$1" in --*) case "$2" in --*) ;; *) ARGS+=("$2");; esac;; esac
  case "$1" in
    --game-dir) GAME="$2"; shift 2;; --gog-installer) GOG_EXE="$2"; shift 2;; --app-dir) APPS="$2"; shift 2;; --data-dir) DATA="$2"; shift 2;;
    *) echo "unknown option $1"; exit 1;;
  esac
done
# the stable app, or (--as-nightly, used by --nightly) the nightly one next to it
APP_NAME="Fallout New Vegas Native"; APP_SHOWN="Fallout: New Vegas"; APP_ID=native; APP_LOG=FalloutNVNative
[ -n "$AS_NIGHTLY" ] && { APP_NAME="Fallout New Vegas Nightly"; APP_SHOWN="Fallout: New Vegas Nightly"; APP_ID=nightly; APP_LOG=FalloutNVNightly; }
installed_game() {     # the game folder an installed app was set up with (for reinstalls and updates)
  local a L v x; for a in "Fallout New Vegas Native" "Fallout New Vegas Nightly"; do
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
if [ -n "$GOG_EXE" ]; then       # unpack the installer into the data folder; the app reads the game from there
  [ -f "$GOG_EXE" ] || { echo "no such file: $GOG_EXE"; exit 1; }
  command -v innoextract >/dev/null || { echo "innoextract is needed for --gog-installer: brew install innoextract"; exit 1; }
  X="$DATA/gog-extract"; rm -rf "$X"; mkdir -p "$X"; echo "== unpacking $GOG_EXE"
  innoextract --gog -s -d "$X" "$GOG_EXE"
  GAME="$(dirname "$(find "$X" -name FalloutNV.exe -print -quit)")"
  [ -f "$GAME/FalloutNV.exe" ] || { echo "FalloutNV.exe not found in the installer"; exit 1; }
fi
[ -n "$GAME" ] || GAME="$(installed_game)"
[ -n "$GAME" ] || { echo "usage: install.sh --game-dir <Fallout New Vegas folder> | --gog-installer <setup_fallout_new_vegas_*.exe>"; exit 1; }
GAME="$(cd "$GAME" && pwd)"
for tool in clang python3; do command -v $tool >/dev/null || { echo "$tool is missing: install the Xcode command line tools (xcode-select --install)"; exit 1; }; done
[ "$(uname -m)" = arm64 ] || { echo "the native build is for Apple Silicon Macs"; exit 1; }
EXE="$GAME/FalloutNV.exe"
[ -f "$EXE" ] || { echo "no FalloutNV.exe in $GAME"; exit 1; }
[ -d "$GAME/Data" ] || { echo "no Data folder in $GAME"; exit 1; }
[ "$(shasum -a 256 "$EXE" | cut -d' ' -f1)" = "$GOG_SHA" ] || { echo "$EXE is not the GOG Fallout: New Vegas 1.4.0.525 release"; exit 1; }
echo "== recompiling $EXE (about ten minutes)"
"$HERE/recomp/build_fnv.sh" "$EXE"
"$HERE/recomp/tools/build_app.sh" "$HERE/recomp/work/fnv" >/dev/null
echo "== the launch window's art, from your own archives"
python3 "$HERE/recomp/tools/fnv_art.py" "$GAME" "$DATA/art" || echo "   (no art: the launch window uses plain colours)"

A="$APPS/$APP_NAME.app"; echo "== installing $A"
mkdir -p "$APPS"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$HERE/recomp/work/fnv/app/FalloutNVNative" "$HERE/recomp/work/fnv/app/shaders.metal" "$HERE/recomp/work/fnv/app/dsr_snapshot.bin" "$A/Contents/MacOS/"
cp "$HERE/recomp/work/fnv/FalloutNV.exe" "$A/Contents/Resources/FalloutNV.exe"
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
if [ "\${1:-}" = --check ]; then git -C "\$REPO" ls-remote origin "refs/heads/\$BRANCH" | cut -f1; exit 0; fi
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
exec "\$B/FalloutNVNative" --exe "\$B/../Resources/FalloutNV.exe" --game "\$GAME" --data "\$DATA" 2>>"\$L"
LAUNCH
chmod +x "$A/Contents/MacOS/launcher"
# The app's executable is the game itself (macOS recognises a game, and turns on Game Mode, only for a bundle whose
# executable is the program): it reads these settings when opened (the launcher script above is for the terminal)
P="$A/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"; plutil -insert log -string "$APP_LOG" "$P"
plutil -insert exe -string FalloutNV.exe "$P"; plutil -insert branch -string "$U_BRANCH" "$P"; plutil -insert built -string "$U_BUILT" "$P"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_SHOWN</string>
  <key>CFBundleIdentifier</key><string>io.github.fallout-nv-macos.$APP_ID</string>
  <key>CFBundleExecutable</key><string>FalloutNVNative</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.0.525</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
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
