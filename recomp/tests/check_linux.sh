#!/usr/bin/env bash
# Checks use synthetic fixtures only; no game executable or assets required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT="$ROOT/build/linux-checks"
mkdir -p "$OUT"
read -ra CF <<< "$(pkg-config --cflags sdl2 freetype2 fontconfig sndfile glew libpng)"
read -ra GL <<< "$(pkg-config --libs sdl2 glew libpng)"
for f in recomp/runtime/rt.c recomp/runtime/win32/*.c recomp/host/linux.c src/renderer/linux/renderer.c; do
    clang -fsyntax-only -D_GNU_SOURCE -I recomp/runtime "${CF[@]}" "$f"
done
clang -O1 -g -D_GNU_SOURCE -ffunction-sections -fdata-sections -Wl,--gc-sections -I recomp/runtime \
    -o "$OUT/winsock" recomp/tests/winsock_linux_test.c -pthread
"$OUT/winsock"
clang -O1 -g -D_GNU_SOURCE -I recomp/runtime -I recomp/runtime/win32 -o "$OUT/dp8" \
    recomp/tests/dp8test.c recomp/runtime/win32/dp8proto.c -pthread
"$OUT/dp8"
clang -O1 -g "${CF[@]}" -o "$OUT/renderer" recomp/tests/renderer_test.c src/renderer/linux/renderer.c "${GL[@]}" -lm
"$OUT/renderer" src/renderer/linux
for test in frame_pacer display_modes; do
    clang -O1 -g -o "$OUT/$test" "recomp/tests/${test}_test.c" -lm
    "$OUT/$test"
done
python3 -m py_compile recomp/host/linux_launcher/*.py recomp/tools/check_edition.py \
    recomp/tools/install_linux.py recomp/tools/prepare_linux_icon.py
python3 recomp/tests/test_lab_test.py
