#!/usr/bin/env bash
# Assembles Folio.app from a SwiftPM build. Xcode isn't required.
#
#   scripts/bundle.sh [debug|release]
#
# Output: build/Folio.app (ad-hoc signed, hardened runtime). For distribution,
# re-sign with a Developer ID and notarize; see docs/RELEASING.md.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/build/Folio.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product Folio
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/Folio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Folio"
sed -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Finder Quick Actions / Services, generated from the tool catalog in code.
"$BIN" --services-json > "$ROOT/build/services.json"
python3 - "$APP/Contents/Info.plist" "$ROOT/build/services.json" <<'PY'
import json, plistlib, sys
plist_path, services_path = sys.argv[1], sys.argv[2]
with open(plist_path, "rb") as f: info = plistlib.load(f)
with open(services_path) as f: info["NSServices"] = json.load(f)
with open(plist_path, "wb") as f: plistlib.dump(info, f)
PY

# App icon, rendered from code and cached between builds.
ICONSET="$ROOT/build/AppIcon.iconset"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --entitlements "$ROOT/Resources/Folio.entitlements" --sign - "$APP" 2>/dev/null
echo "Built $APP ($VERSION, build $BUILD, $CONFIG)"
