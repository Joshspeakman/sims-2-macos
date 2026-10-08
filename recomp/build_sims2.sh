#!/bin/bash
# build_sims2.sh <"The Sims 2 Legacy Collection" folder> [outdir]
# Recompile the player's own Steam copy of The Sims 2 Legacy Collection (EP9/TSBin/Sims2EP9.exe, and ijl15.dll from
# its folder) into C. Steam's DRM wrapper is taken off first (tools/steamstub.py); the game folder is only read.
# Everything generated stays local (work/ is git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="${1:?usage: build_sims2.sh <The Sims 2 Legacy Collection folder> [outdir]}"; OUT="${2:-$HERE/work/sims2}"
BIN="$GAME/EP9/TSBin"
SHA=24041f834e979cc088714713c3207540ff9093f51ff126450a4f7989432156b6          # Steam app 3314070, Sims2EP9.exe as of 2026-10-07
SHA_UNPACKED=7aaf7336249c05c31270416e5abeb5b438f0dc9e6af9d59ff34c6342a5abd9cc
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
[ -f "$BIN/Sims2EP9.exe" ] || { echo "no EP9/TSBin/Sims2EP9.exe in $GAME"; exit 1; }
[ "$(sha "$BIN/Sims2EP9.exe")" = "$SHA" ] || [ -n "${SIMS2_ANY_BUILD:-}" ] || {
  echo "Sims2EP9.exe is not the build this port was made from (Steam updated the game?); SIMS2_ANY_BUILD=1 tries anyway"; exit 1; }
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" install -q capstone==5.0.7 unicorn==2.1.4; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
python3 "$HERE/tools/compiler_compat.py" "${CC:-clang}" "$OUT/compiler-flags.txt"
# arm64: x86's memory ordering for the game's threads (runtime/rt.h RT_TSO); x86-64 has it natively
if [[ "$(uname -m)" == arm64 ]]; then printf '%s -DRT_TSO\n' "$(head -1 "$OUT/compiler-flags.txt")" > "$OUT/compiler-flags.txt.new" && mv "$OUT/compiler-flags.txt.new" "$OUT/compiler-flags.txt"; fi
echo "== Steam DRM"
"$PY" "$HERE/tools/steamstub.py" "$BIN/Sims2EP9.exe" "$OUT/Sims2EP9.exe"
EXE="$OUT/Sims2EP9.exe"
[ "$(sha "$EXE")" = "$SHA_UNPACKED" ] || [ -n "${SIMS2_ANY_BUILD:-}" ] || { echo "unpacked Sims2EP9.exe differs from the expected one"; exit 1; }
echo "== analysis"
"$PY" "$HERE/tools/analyze.py" "$EXE" "$OUT/analysis.json" > "$OUT/analysis.log"
sed -n '/^functions /p; /^decode failures:/p; /^jump tables /p; /^SEH:/p' "$OUT/analysis.log"
echo "== lifting"
"$PY" "$HERE/tools/lift.py" "$EXE" "$OUT/analysis.json" "$OUT" --game sims2 | grep -Ev '^unsupported: \{\}$'
# the game's own DLL, recompiled into the same image set (as build.sh does for Miles and Bink): the Intel JPEG Library
# (screenshots, thumbnails). Its base (0x60000000) is free, so it is lifted as it is.
NIMP=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["imports"]))' "$OUT/image.json")
IMGS=("=")
for rel in ijl15.dll; do
  tag=$(echo "$rel" | tr . _); src="$BIN/$rel"
  [ -f "$src" ] || { echo "missing $src"; exit 1; }
  "$PY" "$HERE/tools/analyze.py" "$src" "$OUT/$tag.json" | head -1
  "$PY" "$HERE/tools/lift.py" "$src" "$OUT/$tag.json" "$OUT" --tag "$tag" --imp-base "$NIMP" | grep -E 'lifted|internal'
  NIMP=$((NIMP + $("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["imports"]))' "$OUT/${tag}_image.json")))
  IMGS+=("$tag=$rel")
done
"$PY" "$HERE/tools/link_tables.py" "$OUT" "${IMGS[@]}"
echo "== compiling"
rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"
JOBS="${SIMS2_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
printf '%s\n' "$OUT"/lift_*.c "$OUT"/*_lift_*.c "$OUT/fntab.c" | xargs -n 1 -P "$JOBS" "$HERE/tools/cc1.sh" "$OUT"
echo "== $(ls "$OUT/obj" | wc -l | tr -d ' ') object files"
# Not linked yet: the runtime has no Sims 2 profile (start-up, paths, registry, Steam API); see docs/SIMS2-PORT.md.
