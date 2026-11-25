#!/bin/bash
# dist/Azur Promilia Launcher.app 을 설치용 DMG로 묶어요 (앱 + 응용 프로그램 폴더 바로가기).
#   ./build-app.sh && ./make-dmg.sh      # dist/Azur-Promilia-Launcher.dmg
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/Azur Promilia Launcher.app"
OUT="${1:-$DIR/dist/Azur-Promilia-Launcher.dmg}"
[ -d "$APP" ] || { echo "먼저 ./build-app.sh 로 앱을 만들어 주세요." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/Azur Promilia Launcher.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Azur Promilia Launcher" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "만들었어요: $OUT"
