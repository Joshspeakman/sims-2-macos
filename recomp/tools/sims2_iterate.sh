#!/bin/bash
# sims2_iterate.sh [relink] : rebuild (everything, or SIMS2_RELINK for runtime-only changes) and run a short windowed
# test session of The Sims 2; prints the end of the log. GAME (the Steam collection folder) and SECS can be set.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"
GAME="${GAME:-/mnt/de23fa52-e674-44dc-b668-d5ca17db46cf/SteamLibrary/steamapps/common/The Sims 2 Legacy Collection}"
SECS="${SECS:-60}"; N=$(date +%H%M%S)
[[ "${1:-}" == relink ]] && export SIMS2_RELINK=1
[[ "${1:-}" == run ]] || ./build_sims2.sh "$GAME" > work/build.log 2>&1 || { echo "build failed"; grep -E "error|undefined" work/build.log | head -20; exit 1; }
DS_TEST=1 W32_AUDIO_MUTE=1 DS_EXIT_AFTER=$SECS DS_RESOLUTION=${DS_RESOLUTION:-1280x720} timeout -s KILL $((SECS + 15)) setsid \
  work/sims2/app/Sims2Linux --exe work/sims2/Sims2EP9.exe --game "$GAME" --data "${SIMS2_DATA:-$HOME/.local/share/sims2-linux-dev}" \
  > work/run-$N.log 2>&1 < /dev/null
echo "run rc=$? log work/run-$N.log"
tail -${TAIL:-30} work/run-$N.log | cut -c1-300
