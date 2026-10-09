#!/bin/bash
# build_runtime.sh <outdir> : compile the runtime + Win32 layer and link with the lifted objects into libgame.dylib
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$1"; mkdir -p "$OUT/obj"
if [[ $(uname -s) == Linux ]]; then exec "$HERE/tools/build_linux.sh" "$OUT"; fi
# Do not mix old objects with a failed parallel build, or publish half a runtime.
LOCK="$OUT/.runtime-build.lock"
mkdir "$LOCK" 2>/dev/null || { echo "runtime build already active: $LOCK" >&2; exit 1; }
STAGE=$(mktemp -d "$OUT/obj/.runtime.XXXXXX")
PIDS=(); FAILED=0
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -z "$pid" ] || wait "$pid" || true; done
  rm -rf "$STAGE"; rmdir "$LOCK"
}
trap cleanup EXIT
CC="${CC:-clang}"
JOBS="${SIMS2_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "invalid SIMS2_BUILD_JOBS: $JOBS" >&2; exit 1; }
wait_jobs() {
  for pid in "${PIDS[@]:-}"; do if [ -n "$pid" ] && ! wait "$pid"; then FAILED=1; fi; done
  PIDS=()
  [ "$FAILED" -eq 0 ]
}
queue_job() { PIDS+=("$!"); if [ "${#PIDS[@]}" -ge "$JOBS" ]; then wait_jobs; fi; }
python3 "$HERE/tools/gen_imptab.py" "$OUT/imptab.c" "$HERE"/runtime/win32/*.c
# the edition (Fallout: New Vegas, or Dungeon Siege II and Broken World) by the executable in the build folder
EXE="$OUT/DungeonSiege2.exe"; [[ -f "$OUT/FalloutNV.exe" ]] && EXE="$OUT/FalloutNV.exe"
EDITION_FLAGS=()
if [[ -f "$OUT/Sims2EP9.exe" ]]; then                     # The Sims 2 (build_sims2.sh checked the executable)
  EDITION_FLAGS=(-DSIMS2_EDITION); [[ "$(uname -m)" == arm64 ]] && EDITION_FLAGS+=(-DRT_TSO)
elif [[ -f "$EXE" ]]; then
  EDITION=$(PYTHONPATH="$HERE/tools" python3 -c 'import sys; from editions import identify; print(identify(sys.argv[1], prepared=True))' "$EXE" 2>/dev/null || echo gog)
  [[ "$EDITION" == broken-world ]] && EDITION_FLAGS=(-DDS2_BROKEN_WORLD)
  [[ "$EDITION" == fnv ]] && EDITION_FLAGS=(-DFNV_EDITION)
  [[ "$EDITION" == fnv && "$(uname -m)" == arm64 ]] && EDITION_FLAGS+=(-DRT_TSO)       # as the lifted code (build_fnv.sh)
fi
printf '%s\n' "${EDITION_FLAGS[@]:-}" > "$OUT/edition-flags.txt"
# MojoShader (Direct3D 9 shader bytecode -> Metal for Fallout: New Vegas's own shaders, d3d9_shader.c): the Metal profile only
MOJO=(-DSUPPORT_PROFILE_D3D=0 -DSUPPORT_PROFILE_BYTECODE=0 -DSUPPORT_PROFILE_HLSL=0 -DSUPPORT_PROFILE_ARB1=0 -DSUPPORT_PROFILE_ARB1_NV=0
      -DSUPPORT_PROFILE_SPIRV=0 -DSUPPORT_PROFILE_GLSPIRV=0 -DSUPPORT_PROFILE_GLSLES=0 -DSUPPORT_PROFILE_GLSLES3=0
      -DSUPPORT_PROFILE_GLSL=0 -DSUPPORT_PROFILE_GLSL120=0 -I "$HERE/third_party/mojoshader")
mkdir -p "$STAGE/rt/mojo"
for f in "$HERE"/third_party/mojoshader/mojoshader.c "$HERE"/third_party/mojoshader/mojoshader_common.c "$HERE"/third_party/mojoshader/profiles/*.c; do
  "$CC" -c -O2 -w "${MOJO[@]}" -o "$STAGE/rt/mojo/$(basename "$f" .c).o" "$f" &
  queue_job
done
for f in "$HERE"/runtime/rt.c "$HERE"/runtime/win32/*.c "$OUT/imptab.c"; do
  opt=-O2; [ "$(basename "$f")" = native.c ] && opt=-O3   # the runtime sits under every frame (indirect calls, Direct3D): optimised; native.c's hot loops most
  "$CC" -c $opt -g -ffp-contract=off -fno-strict-aliasing -Wall -Wno-unused-function ${EDITION_FLAGS[@]+"${EDITION_FLAGS[@]}"} -I "$HERE/runtime" -I "$HERE/runtime/win32" \
    -I "$HERE/third_party/mojoshader" -I "$HERE/third_party/minimp3" -o "$STAGE/rt/$(basename "$f" .c).o" "$f" &
  queue_job
done
wait_jobs
"$CC" -shared -o "$STAGE/libgame.dylib" "$OUT"/obj/*.o "$STAGE"/rt/*.o "$STAGE"/rt/mojo/*.o -framework CoreText -framework CoreGraphics -framework CoreFoundation -framework AudioToolbox -lz
[ ! -d "$OUT/obj/rt" ] || mv "$OUT/obj/rt" "$STAGE/previous"
mv "$STAGE/rt" "$OUT/obj/rt"
mv "$STAGE/libgame.dylib" "$OUT/libgame.dylib"
