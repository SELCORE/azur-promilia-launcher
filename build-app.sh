#!/bin/bash
# "Azur Promilia Launcher.app"을 만들어요 (SwiftUI 창 + azurctl.sh).
#   ./build-app.sh                      # ./dist/Azur Promilia Launcher.app
#   ./build-app.sh ~/Applications/"Azur Promilia Launcher.app"
# 필요한 것: Xcode 명령줄 도구 (xcode-select --install)
set -euo pipefail

VERSION="0.4.2"
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

# 아이콘: app/local-icon.png(개인용, 저장소에 안 올라감)가 있으면 그걸, 없으면 공개용 app/icon.png를 써요.
# 릴리스용으로 빌드할 때는 PUBLIC_ICON=1 로 개인 아이콘을 무시해요.
ICON_KEY=""
ICON_SRC="$DIR/app/icon.png"
[ -f "$DIR/app/local-icon.png" ] && [ "${PUBLIC_ICON:-0}" != 1 ] && ICON_SRC="$DIR/app/local-icon.png"
if [ -f "$ICON_SRC" ]; then
  ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ICON_SRC" --out "$ISET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ISET/icon_${sz}x${sz}@2x.png" >/dev/null
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
