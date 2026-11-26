#!/usr/bin/env bash
# Opens this checkout's Folio (optionally with files) and saves a PNG of every
# window that becomes key, then quits that instance.
#
#   scripts/snapshot.sh [file ...]        → build/snapshots/*.png
#   SCHEME=dark scripts/snapshot.sh file  → same, in dark mode (default: light)
#   WAIT=6 scripts/snapshot.sh big.pdf    → wait longer before quitting
#
# Uses the app's own drawing (Sources/Folio/WindowSnapshots.swift), so it needs no
# screen-recording permission. Runs a separate instance (-n) and quits only that one,
# so several checkouts can snapshot at the same time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Folio.app"
OUT="$ROOT/build/snapshots"
mkdir -p "$OUT"
args=(-n --env "FOLIO_SNAPSHOT_DIR=$OUT")
args+=(--env "FOLIO_APPEARANCE=${SCHEME:-light}")
open "${args[@]}" -a "$APP" "$@"
sleep "${WAIT:-4}"
pkill -f "$APP/Contents/MacOS/Folio" 2>/dev/null || true
ls -1t "$OUT" | head -20
