#!/bin/bash
# build_runtime.sh <outdir> : compile the runtime + Win32 layer and link with the lifted objects into libgame.dylib
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$1"; mkdir -p "$OUT/obj/rt"
if [[ $(uname -s) == Linux ]]; then exec "$HERE/tools/build_linux.sh" "$OUT"; fi
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
mkdir -p "$OUT/obj/rt/mojo"
for f in "$HERE"/third_party/mojoshader/mojoshader.c "$HERE"/third_party/mojoshader/mojoshader_common.c "$HERE"/third_party/mojoshader/profiles/*.c; do
  clang -c -O2 -w "${MOJO[@]}" -o "$OUT/obj/rt/mojo/$(basename "$f" .c).o" "$f" &
done
for f in "$HERE"/runtime/rt.c "$HERE"/runtime/win32/*.c "$OUT/imptab.c"; do
  opt=-O2; [ "$(basename "$f")" = native.c ] && opt=-O3   # the runtime sits under every frame (indirect calls, Direct3D): optimised; native.c's hot loops most
  clang -c $opt -g -ffp-contract=off -fno-strict-aliasing -Wall -Wno-unused-function ${EDITION_FLAGS[@]+"${EDITION_FLAGS[@]}"} -I "$HERE/runtime" -I "$HERE/runtime/win32" \
    -I "$HERE/third_party/mojoshader" -I "$HERE/third_party/minimp3" -o "$OUT/obj/rt/$(basename "$f" .c).o" "$f" &
done; wait
clang -shared -o "$OUT/libgame.dylib" "$OUT"/obj/*.o "$OUT"/obj/rt/*.o "$OUT"/obj/rt/mojo/*.o -framework CoreText -framework CoreGraphics -framework CoreFoundation -framework AudioToolbox -lz
