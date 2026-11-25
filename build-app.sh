#!/bin/bash
# "Azur Promilia Launcher.app"을 만들어요.
#   ./build-app.sh                      # ./dist/Azur Promilia Launcher.app
#   ./build-app.sh ~/Applications/"Azur Promilia Launcher.app"
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/dist/Azur Promilia Launcher.app}"
PB=/usr/libexec/PlistBuddy
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
osacompile -o "$OUT" "$DIR/app/main.applescript" 2>"$TMP/osacompile.err" \
  || { cat "$TMP/osacompile.err" >&2; exit 1; }
cp "$DIR/azurctl.sh" "$DIR/extract_zip.py" "$OUT/Contents/Resources/"
chmod +x "$OUT/Contents/Resources/azurctl.sh"

PLIST="$OUT/Contents/Info.plist"
"$PB" -c "Set :CFBundleIdentifier local.azur-promilia-launcher" "$PLIST" 2>/dev/null \
  || "$PB" -c "Add :CFBundleIdentifier string local.azur-promilia-launcher" "$PLIST"
"$PB" -c "Set :CFBundleName Azur Promilia Launcher" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :CFBundleShortVersionString string 0.1.0" "$PLIST" 2>/dev/null \
  || "$PB" -c "Set :CFBundleShortVersionString 0.1.0" "$PLIST"
codesign --force --sign - "$OUT" 2>/dev/null

echo "만들었어요: $OUT"
