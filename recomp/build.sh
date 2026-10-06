#!/bin/bash
# build.sh <DungeonSiege2.exe> [outdir]
# Recompile the user's own GOG 2.3 executable and DLLs for the host CPU:
# analysis -> C -> libgame.dylib.
# Everything generated is derived from the executable and stays local (work/ is git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXE="${1:?usage: build.sh <DungeonSiege2.exe> [outdir]}"; OUT="${2:-$HERE/work/full}"
python3 "$HERE/tools/check_edition.py" "$EXE"
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" install -q capstone==5.0.7 unicorn==2.1.4; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cp "$EXE" "$OUT/DungeonSiege2.exe"                  # a copy (no patches so far)
EXE="$OUT/DungeonSiege2.exe"
echo "== analysis"; "$PY" "$HERE/tools/analyze.py" "$EXE" "$OUT/analysis.json" | head -6
echo "== lifting";  "$PY" "$HERE/tools/lift.py" "$EXE" "$OUT/analysis.json" "$OUT"
# the Miles Sound System the game ships (system/mss32.dll and the providers it loads) and Bink, recompiled the same way;
# game folder paths, so the build needs the folder the executable came from. Msseax.m3d (hardware EAX) is left out.
GAME="$(cd "$(dirname "$1")" && pwd)"; IMGS=("=")
if [ -f "$GAME/system/mss32.dll" ]; then
  mkdir -p "$OUT/miles"; NIMP=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["imports"]))' "$OUT/image.json")
  for rel in system/mss32.dll system/mss/msssoft.m3d system/mss/mssmp3.asi system/mss/mssdsp.flt system/binkw32.dll; do
    tag=$(basename "$rel" | tr . _); [ -f "$GAME/$rel" ] || { echo "missing $GAME/$rel"; exit 1; }
    "$PY" "$HERE/tools/analyze.py" "$GAME/$rel" "$OUT/miles/$tag.json" | head -1
    "$PY" "$HERE/tools/lift.py" "$GAME/$rel" "$OUT/miles/$tag.json" "$OUT" --tag "$tag" --imp-base "$NIMP" | grep -E 'lifted|internal'
    NIMP=$((NIMP + $("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["imports"]))' "$OUT/${tag}_image.json")))
    IMGS+=("$tag=$rel")
  done
fi
"$PY" "$HERE/tools/link_tables.py" "$OUT" "${IMGS[@]}"
echo "== compiling"
rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"
JOBS="${DS_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
printf '%s\n' "$OUT"/lift_*.c "$OUT"/*_lift_*.c "$OUT/fntab.c" | xargs -n 1 -P "$JOBS" "$HERE/tools/cc1.sh" "$OUT"
rm -f "$OUT/obj/rt.o"
"$HERE/tools/build_runtime.sh" "$OUT"            # runtime + Win32 layer, then the link
if [[ $(uname -s) == Linux ]]; then echo "== $OUT/libgame.so"; else echo "== $OUT/libgame.dylib"; fi
