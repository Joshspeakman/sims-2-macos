#!/bin/bash
# build_fnv.sh <FalloutNV.exe> [outdir]
# Recompile the user's own GOG Fallout: New Vegas 1.4.0.525 FalloutNV.exe (and binkw32.dll from its folder) into C and
# compile every generated file for the host CPU. This stage stops at object files: the runtime does not run Fallout
# yet (docs/FNV-RUNTIME-GAPS.md). Everything generated stays local (work/ is git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXE="${1:?usage: build_fnv.sh <FalloutNV.exe> [outdir]}"; OUT="${2:-$HERE/work/fnv}"
SHA=89e7020487e80f20ddc92ea641c4433b2c6839a82f45a076e414d167d11dd0fe          # GOG 1.4.0.525 (installer 12010)
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
[ "$(sha "$EXE")" = "$SHA" ] || { echo "not the original GOG 1.4.0.525 FalloutNV.exe"; exit 1; }
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" install -q capstone==5.0.7 unicorn==2.1.4; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
GAME="$(cd "$(dirname "$EXE")" && pwd)"
cp "$EXE" "$OUT/FalloutNV.exe"; EXE="$OUT/FalloutNV.exe"
echo "== analysis"
"$PY" "$HERE/tools/analyze.py" "$EXE" "$OUT/analysis.json" > "$OUT/analysis.log"
sed -n '/^functions /p; /^decode failures:/p; /^jump tables /p; /^SEH:/p' "$OUT/analysis.log"
echo "== lifting"
"$PY" "$HERE/tools/lift.py" "$EXE" "$OUT/analysis.json" "$OUT/c" --game fnv | grep -Ev '^unsupported: \{\}$'
# Bink (the game's own DLL), recompiled into the same image set the way build.sh does for Dungeon Siege II
NIMP=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["imports"]))' "$OUT/c/image.json")
"$PY" "$HERE/tools/analyze.py" "$GAME/binkw32.dll" "$OUT/binkw32_dll.json" | head -1
"$PY" "$HERE/tools/lift.py" "$GAME/binkw32.dll" "$OUT/binkw32_dll.json" "$OUT/c" --tag binkw32_dll --imp-base "$NIMP" | grep -E 'lifted|internal'
"$PY" "$HERE/tools/link_tables.py" "$OUT/c" = binkw32_dll=binkw32.dll
echo "== compiling (generated C only)"
rm -rf "$OUT/c/obj"; mkdir -p "$OUT/c/obj"
JOBS="${FNV_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
printf '%s\n' "$OUT"/c/lift_*.c "$OUT"/c/*_lift_*.c "$OUT/c/fntab.c" | xargs -n 1 -P "$JOBS" "$HERE/tools/cc1.sh" "$OUT/c"
echo "== $(ls "$OUT/c/obj" | wc -l | tr -d ' ') object files in $OUT/c/obj"
