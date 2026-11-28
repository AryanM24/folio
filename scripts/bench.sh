#!/usr/bin/env bash
# Times Folio against the macOS command-line tools you'd otherwise reach for, on inputs
# generated here, and writes the results to site/bench.json for the landing page.
#
#   scripts/bench.sh            # needs build/Folio.app (make app)
#
# Every comparison does the same job: same inputs, same target format, outputs written to
# disk. Each number is the best of three runs, so a cold cache doesn't decide the result.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOLIO="$ROOT/build/Folio.app/Contents/Helpers/folio"
[[ -x "$FOLIO" ]] || { echo "Build the app first: make app" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

now() { python3 -c 'import time; print(time.perf_counter())'; }
# best <label> <command…>: runs the command three times in a fresh output folder, prints ms.
best() {
  shift  # the label is for readers of this script
  local fastest=999999999
  for _ in 1 2 3; do
    rm -rf "$WORK/out" && mkdir -p "$WORK/out"
    local s e
    s=$(now)
    "$@" >"$WORK/log" 2>&1 || { echo "Failed: $*" >&2; cat "$WORK/log" >&2; exit 1; }
    e=$(now)
    fastest=$(python3 -c "print(min($fastest, round(($e - $s) * 1000)))")
  done
  echo "$fastest"
}

echo "Preparing inputs in $WORK…" >&2
# 40 images, 12 MP each, as HEIC. (Wallpaper gradients: easier to encode than photos.)
SRC="/System/Library/Desktop Pictures/Mac Blue.heic"
mkdir -p "$WORK/photos"
sips -s format heic -z 3024 4032 "$SRC" --out "$WORK/photos/0.heic" >/dev/null
for i in $(seq 1 39); do cp "$WORK/photos/0.heic" "$WORK/photos/$i.heic"; done
# Five minutes of 48 kHz stereo audio.
python3 - "$WORK/talk.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    frames = bytearray()
    for i in range(48000 * 300):
        v = int(8000 * math.sin(2 * math.pi * 220 * i / 48000) * (0.6 + 0.4 * math.sin(i / 9000)))
        frames += struct.pack("<hh", v, v)
    w.writeframes(bytes(frames))
PY
# Ten seconds of 4K slow-motion video (HEVC, 240 fps), cut from a macOS wallpaper clip.
avconvert --source "/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Dark Landscape.mov" \
  --preset PresetPassthrough --start 0 --duration 10 --output "$WORK/clip.mov" >/dev/null

sips_loop() { for f in "$WORK"/photos/*.heic; do sips -s format jpeg -s formatOptions 85 "$f" --out "$WORK/out/" >/dev/null; done; }

echo "Photos…" >&2
p_folio=$(best folio "$FOLIO" convert "$WORK"/photos/*.heic --to jpeg --out "$WORK/out")
p_sips=$(best sips sips_loop)
echo "Audio…" >&2
a_folio=$(best folio "$FOLIO" convert "$WORK/talk.wav" --to m4a --out "$WORK/out")
a_af=$(best afconvert afconvert -f m4af -d aac -b 256000 "$WORK/talk.wav" "$WORK/out/talk.m4a")
echo "Video…" >&2
v_folio=$(best folio "$FOLIO" convert "$WORK/clip.mov" --to mp4 --quality small --out "$WORK/out")
v_av=$(best avconvert avconvert --source "$WORK/clip.mov" --preset PresetHEVC1920x1080 --output "$WORK/out/clip.mp4" --replace)

MACHINE="$(sysctl -n machdep.cpu.brand_string) Mac, macOS $(sw_vers -productVersion)"
python3 - "$ROOT/site/bench.json" "$MACHINE" "$p_folio" "$p_sips" "$a_folio" "$a_af" "$v_folio" "$v_av" <<'PY'
import json, sys
out, machine, pf, ps, af, aa, vf, va = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:])
rows = [
    {"task": "Convert 40 12-megapixel HEIC images to JPEG", "folio_ms": pf, "other_ms": ps, "other": "sips, one by one"},
    {"task": "Shrink 10 s of 4K slow-motion video to share", "folio_ms": vf, "other_ms": va, "other": "avconvert, HEVC 1080p"},
    {"task": "Five minutes of audio, WAV to AAC", "folio_ms": af, "other_ms": aa, "other": "afconvert"},
]
json.dump({"machine": "an " + machine, "rows": rows}, open(out, "w"), indent=2)
for r in rows:
    print(f"{r['task']:<44} folio {r['folio_ms']:>6} ms   {r['other']:<24} {r['other_ms']:>6} ms")
PY
