#!/usr/bin/env bash
# macOS Metal upload regression; no game files required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sims2-ring.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
clang -O1 -g -fobjc-arc -fsanitize=address,undefined \
    -framework Metal -framework Foundation -framework QuartzCore \
    "$ROOT/recomp/tests/renderer_ring_test.m" -o "$OUT/ring"
(cd "$ROOT/src/renderer" && DSR_SHADER_CACHE=0 "$OUT/ring")
