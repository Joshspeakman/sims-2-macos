#!/bin/bash
# CPU and real Metal tests use synthetic data, never proprietary game assets.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT="$ROOT/build/macos-checks"
mkdir -p "$OUT"
for name in thread_suspend cursor_copy host_services texture_cache interlocked frame_pacer display_modes window_geometry; do
  clang -O1 -g -ffunction-sections -fdata-sections -Wl,-dead_strip -I recomp/runtime \
    "recomp/tests/${name}_test.c" -o "$OUT/$name"
  if [[ "$name" != texture_cache ]]; then "$OUT/$name"; fi
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DSR_TEXTURE_CACHE_DIR="$TMP" "$OUT/texture_cache" prime
DSR_TEXTURE_CACHE_DIR="$TMP" "$OUT/texture_cache" reuse
python3 recomp/tests/runtime_build_test.py
clang -fsyntax-only -fobjc-arc -DSIMS2_EDITION -I recomp/runtime recomp/host/main.m
MOJO=(-DSUPPORT_PROFILE_D3D=0 -DSUPPORT_PROFILE_BYTECODE=0 -DSUPPORT_PROFILE_HLSL=0
      -DSUPPORT_PROFILE_ARB1=0 -DSUPPORT_PROFILE_ARB1_NV=0 -DSUPPORT_PROFILE_SPIRV=0
      -DSUPPORT_PROFILE_GLSPIRV=0 -DSUPPORT_PROFILE_GLSLES=0 -DSUPPORT_PROFILE_GLSLES3=0
      -DSUPPORT_PROFILE_GLSL=0 -DSUPPORT_PROFILE_GLSL120=0 -I recomp/third_party/mojoshader)
mkdir -p "$OUT/mojo"
for f in recomp/third_party/mojoshader/mojoshader.c recomp/third_party/mojoshader/mojoshader_common.c recomp/third_party/mojoshader/profiles/*.c; do
  clang -O1 "${MOJO[@]}" -c "$f" -o "$OUT/mojo/$(basename "$f" .c).o"
done
clang -O1 -g -fobjc-arc -I recomp/third_party/mojoshader recomp/tests/mojo_metal_test.m "$OUT"/mojo/*.o -framework Metal -framework Foundation -o "$OUT/mojo_metal"
cp src/renderer/shaders.metal "$OUT/"
clang -O1 -g -I recomp/runtime -I recomp/third_party/mojoshader -c recomp/tests/ff_shader_fixture.c -o "$OUT/ff_shader_fixture.o"
clang -O1 -g -fobjc-arc -Wl,-dead_strip recomp/tests/metal_renderer_test.m "$OUT/ff_shader_fixture.o" -framework Metal -framework Foundation -framework QuartzCore -o "$OUT/metal_renderer"
set +e
"$OUT/mojo_metal"
RC=$?
if [[ "$RC" == 0 ]]; then
  DSR_CACHE_DIR="$TMP/metal" "$OUT/metal_renderer"
  RC=$?
fi
set -e
if [[ "$RC" == 77 && "${CI:-}" == true ]]; then
  echo 'Metal execution unavailable on this CI runner; compilation and CPU regressions passed. Run locally for GPU coverage.'
else
  exit "$RC"
fi
