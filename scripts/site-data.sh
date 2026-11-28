#!/usr/bin/env bash
# Writes site/formats.json from the app's own `folio formats --json`, so the landing page's
# format map can never promise a conversion the app doesn't do.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOLIO="$ROOT/build/Folio.app/Contents/Helpers/folio"
[[ -x "$FOLIO" ]] || { echo "Build the app first: make app" >&2; exit 1; }

"$FOLIO" formats --json | python3 -c '
import json, sys
FAMILY = {"pdf": "pdf", **{f: "document" for f in "docx doc rtf odt html md txt".split()},
          **{f: "spreadsheet" for f in "xlsx ods csv tsv json".split()},
          **{f: "image" for f in "png jpeg heic avif tiff gif bmp jp2 webp jxl".split()},
          **{f: "audio" for f in "m4a alac flac wav aiff mp3".split()}, **{f: "video" for f in "mp4 mov m4v".split()}}
# The sources worth showing on the page, in order; the full list is in docs/FORMATS.md.
SHOWN = "pdf docx rtf odt html md txt xlsx ods csv json heic png jpeg avif tiff gif webp wav flac m4a mp3 mov mp4".split()
data = json.load(sys.stdin)
pairs = {}
for p in data["pairs"]:
    pairs.setdefault(p["from"], []).append({k: p[k] for k in ("to", "fidelity", "lossless_available", "drops") if k in p})
out = {"version": data.get("version"), "pairs": [{"from": f, "family": FAMILY[f], "targets": pairs[f]} for f in SHOWN if f in pairs]}
json.dump(out, sys.stdout, indent=1)
' > "$ROOT/site/formats.json"
echo "Wrote site/formats.json"
