#!/bin/bash
# "Azur Promilia Launcher.app"을 만들어요 (SwiftUI 창 + azurctl.sh).
#   ./build-app.sh                      # ./dist/Azur Promilia Launcher.app
#   ./build-app.sh ~/Applications/"Azur Promilia Launcher.app"
# 필요한 것: Xcode 명령줄 도구 (xcode-select --install)
set -euo pipefail

VERSION="0.3.2"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/dist/Azur Promilia Launcher.app}"
EXE="AzurPromiliaLauncher"

mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -o "$OUT/Contents/MacOS/$EXE" "$DIR/app/Launcher.swift"

cp "$DIR/azurctl.sh" "$DIR/extract_zip.py" "$DIR/rename_font.py" "$OUT/Contents/Resources/"
chmod +x "$OUT/Contents/Resources/azurctl.sh"

# 개인 아이콘 (선택): app/local-icon.png가 있으면 앱 아이콘으로 써요. 저장소와 릴리스에는 들어가지 않아요.
ICON_KEY=""
if [ -f "$DIR/app/local-icon.png" ]; then
  ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$DIR/app/local-icon.png" --out "$ISET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$DIR/app/local-icon.png" --out "$ISET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ISET" -o "$OUT/Contents/Resources/AppIcon.icns" && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
  rm -rf "$(dirname "$ISET")"
fi

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>local.azur-promilia-launcher</string>
  <key>CFBundleName</key><string>Azur Promilia Launcher</string>
  <key>CFBundleDisplayName</key><string>아주르 프로밀리아 런처</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_KEY
</dict>
</plist>
EOF

codesign --force --sign - "$OUT" 2>/dev/null
echo "만들었어요: $OUT"
