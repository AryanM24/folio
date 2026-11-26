#!/usr/bin/env bash
# Measures cold launch (process start → first window on screen) and quit time.
# Targets: launch < 1 s, quit < 1 s. Prints both in milliseconds.
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Folio.app"
now() { python3 -c 'import time; print(int(time.time()*1000))'; }
windows() { osascript -e 'tell application "System Events" to count windows of process "Folio"' 2>/dev/null || echo 0; }

osascript -e 'quit app "Folio"' 2>/dev/null || true
sleep 1
start=$(now)
open "$APP"
until [[ "$(windows)" -gt 0 ]]; do sleep 0.02; done
launch=$(( $(now) - start ))

start=$(now)
osascript -e 'quit app "Folio"'
while pgrep -x Folio >/dev/null; do sleep 0.02; done
quit=$(( $(now) - start ))

echo "launch: ${launch} ms (target < 1000)"
echo "quit:   ${quit} ms (target < 1000)"
[[ $launch -lt 1000 && $quit -lt 1000 ]]
