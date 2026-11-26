#!/bin/bash
# azurctl: CrossOver 없이 무료 Wine + DXMT로 넥슨 플러그와 아주르 프로밀리아를 돌리는 런처의 핵심 스크립트.
#
#   ./azurctl.sh setup            Wine, DXMT, 넥슨 플러그, NGM을 설치하고 설정해요 (처음 한 번)
#   ./azurctl.sh plug             넥슨 플러그를 켜요
#   ./azurctl.sh stop             이 런처의 Wine 프로세스를 모두 종료해요
#   ./azurctl.sh status           설치 상태를 보여줘요
#   ./azurctl.sh settings         설정 보기 / set <이름> <값> 으로 바꾸기
#     metal_hud(0/1) retina(0/1) left_cmd_ctrl(0/1) custom_resolution(0/1) width height custom_fps(0/1) fps
#
# 개별 단계: install-runtime, init-prefix, install-webview2, install-plug, install-ngm,
#           configure, link-game, import-crossover, game-direct, winecfg, shell
# 내려받는 곳: 이 저장소의 GitHub 릴리스(직접 빌드한 Wine + DXMT 런타임), Microsoft(WebView2), 넥슨 공식 서버.
set -euo pipefail

APP_HOME="${AZUR_HOME:-$HOME/Library/Application Support/Azur Promilia Launcher}"
WINE_DIR="$APP_HOME/wine"
PREFIX="$APP_HOME/prefix"
LOG_DIR="$APP_HOME/logs"
DRIVE_C="$PREFIX/drive_c"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Wine + DXMT 런타임: CodeWeavers가 공개한 CrossOver 소스로 이 저장소의 GitHub Actions에서 직접 빌드하고
# DXMT 공식 릴리스를 넣은 것이에요 (runtime/build-runtime.sh). 이 저장소의 릴리스에서 받아요.
RUNTIME_TAG="runtime-cx26.3.0-dxmt0.80-p2"
RUNTIME_NAME="azur-runtime-cx26.3.0-dxmt0.80-p2"
RUNTIME_URL="https://github.com/SELCORE/azur-promilia-launcher/releases/download/$RUNTIME_TAG/$RUNTIME_NAME.tar.xz"
RUNTIME_SHA256="efb294151e8c5d932215b30c77cd1826b9115aa77be205e92bfd14571c1db593"

PLUG_URL="https://platform.nexon.com/NexonPlug/Install/InstallData/65538.z00"
NGM_URL="https://platform.nexon.com/NGM/Bin"
UA="Mozilla/5.0"
# Wine에서는 Chromium 계열(넥슨 플러그, WebView2) 화면의 GPU 렌더링이 검게 나와서 소프트웨어 렌더링을 써요.
GL_FLAGS="--use-gl=swiftshader --use-angle=swiftshader --in-process-gpu"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '주의: %s\n' "$*" >&2; }
die()  { printf '오류: %s\n' "$*" >&2; exit 1; }

wine_env() { # 런타임에 넣어 둔 FreeType, GnuTLS 등을 Wine이 찾도록 해요
  env WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1 WINEESYNC=1 \
    DXMT_LOG_PATH="$LOG_DIR" DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:/usr/lib" "$@"
}
w() { wine_env "$WINE_DIR/bin/wine" "$@"; }
wserver() { wine_env "$WINE_DIR/bin/wineserver" "$@"; }
reg_add() { w reg add "$@" /f >/dev/null 2>&1 || die "레지스트리 설정 실패: $*"; }
need_wine()   { [ -x "$WINE_DIR/bin/wine" ] || die "Wine이 없어요. 먼저 ./azurctl.sh install-runtime"; }
need_prefix() { need_wine; [ -d "$DRIVE_C" ] || die "Wine 환경이 없어요. 먼저 ./azurctl.sh init-prefix"; }
running_in_prefix() { w tasklist 2>/dev/null | grep -qiE "^($1)\.exe"; }

fetch() { # url dest  (터미널이면 진행 막대, 앱에서 돌 때는 조용히)
  echo "받는 중: $1"
  if [ -t 2 ]; then
    curl -fL -# --retry 3 -A "$UA" -o "$2" "$1"
  else
    curl -fsSL --retry 3 -A "$UA" -o "$2" "$1"
  fi
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

cmd_install_runtime() { # [--from <런타임 tar.xz>]  Wine + DXMT 런타임 설치
  mkdir -p "$APP_HOME"
  local tmp; tmp="$(mktemp -d)"
  if [ "${1:-}" = "--from" ]; then
    cp "$2" "$tmp/runtime.tar.xz"
  else
    fetch "$RUNTIME_URL" "$tmp/runtime.tar.xz"
    [ "$(sha_of "$tmp/runtime.tar.xz")" = "$RUNTIME_SHA256" ] || { rm -rf "$tmp"; die "런타임 파일 체크섬이 맞지 않아요."; }
  fi
  mkdir -p "$tmp/x" && tar -xJf "$tmp/runtime.tar.xz" -C "$tmp/x"
  [ -x "$tmp/x/wine/bin/wine" ] && [ -f "$tmp/x/wine/lib/wine/x86_64-unix/winemetal.so" ] \
    || { rm -rf "$tmp"; die "런타임 압축 안에 Wine이나 DXMT가 없어요."; }
  xattr -dr com.apple.quarantine "$tmp/x/wine" 2>/dev/null || true
  rm -rf "$WINE_DIR"; mv "$tmp/x/wine" "$WINE_DIR"; rm -rf "$tmp"
  echo "$RUNTIME_NAME" > "$WINE_DIR/.azur-runtime"   # 어떤 런타임인지 기록 (바뀌면 다시 받아요)
  echo "Wine: $(w --version 2>/dev/null) + DXMT"
}

runtime_current() { [ -x "$WINE_DIR/bin/wine" ] && [ "$(cat "$WINE_DIR/.azur-runtime" 2>/dev/null)" = "$RUNTIME_NAME" ]; }

cmd_init_prefix() {
  need_wine
  mkdir -p "$LOG_DIR"
  if [ ! -d "$DRIVE_C" ]; then
    say "Wine 환경 만들기 (1~2분)"
    WINEDLLOVERRIDES="mscoree,mshtml=" w wineboot -i >"$LOG_DIR/wineboot.log" 2>&1 || true
    wserver -w
  fi
  [ -d "$DRIVE_C" ] || die "Wine 환경을 만들지 못했어요. 로그: $LOG_DIR/wineboot.log"
  reg_add 'HKCU\Software\Wine' /v Version /t REG_SZ /d win11
  [ -f "$WINE_DIR/lib/wine/x86_64-windows/winemetal.dll" ] && cp "$WINE_DIR/lib/wine/x86_64-windows/winemetal.dll" "$DRIVE_C/windows/system32/winemetal.dll"
  echo "Wine 환경: $PREFIX"
}

WV2_APPGUID='{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
WV2_BOOTSTRAP_URL="https://go.microsoft.com/fwlink/p/?LinkId=2124703"   # Microsoft 공식 WebView2 설치 프로그램
webview2_version() {
  ls "$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView/Application" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1
}
webview2_freeze() {
  # Wine에서 동작이 확인된 버전에 고정해요. 자동 업데이트로 최신 버전이 깔리면 NGM 화면이 안 뜰 수 있어요.
  reg_add 'HKLM\Software\Policies\Microsoft\EdgeUpdate' /v "Update$WV2_APPGUID" /t REG_DWORD /d 0
  reg_add 'HKLM\Software\Wow6432Node\Policies\Microsoft\EdgeUpdate' /v "Update$WV2_APPGUID" /t REG_DWORD /d 0
  local s
  for s in edgeupdate edgeupdatem; do
    w reg query "HKLM\\System\\CurrentControlSet\\Services\\$s" >/dev/null 2>&1 \
      && reg_add "HKLM\\System\\CurrentControlSet\\Services\\$s" /v Start /t REG_DWORD /d 4
  done
  return 0
}

cmd_install_webview2() { # [--from <EdgeWebView 폴더>]  WebView2 런타임 (NGM 설치 화면에 필요)
  need_prefix
  mkdir -p "$LOG_DIR"
  local key="HKLM\\Software\\Wow6432Node\\Microsoft\\EdgeUpdate\\Clients\\$WV2_APPGUID" ver
  if [ "${1:-}" = "--from" ]; then
    local src="$2"
    ver="$(ls "$src/Application" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
    [ -n "$ver" ] || die "WebView2 런타임 버전 폴더를 찾지 못했어요: $src/Application"
    local dest="$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView"
    mkdir -p "$(dirname "$dest")"; rm -rf "$dest"
    cp -cR "$src" "$dest" 2>/dev/null || cp -R "$src" "$dest"
    reg_add "$key" /v location /t REG_SZ /d 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application'
    reg_add "$key" /v name /t REG_SZ /d 'Microsoft Edge WebView2 Runtime'
    reg_add "$key" /v pv /t REG_SZ /d "$ver"
  elif [ -z "$(webview2_version)" ]; then
    # 최신 WebView2는 Wine에서 잘 돌지 않아요. 설치하는 동안만 Windows 7로 인식시키면
    # Microsoft가 Windows 7용 마지막 버전(109)을 줘요. CrossOver 보틀에도 이 버전이 깔려 있어요.
    fetch "$WV2_BOOTSTRAP_URL" "$DRIVE_C/windows/temp/MicrosoftEdgeWebview2Setup.exe"
    reg_add 'HKCU\Software\Wine' /v Version /t REG_SZ /d win7
    echo "WebView2 설치 중 (Microsoft 서버에서 약 150MB를 받아요)"
    w 'C:\windows\temp\MicrosoftEdgeWebview2Setup.exe' /silent /install >"$LOG_DIR/webview2-install.log" 2>&1 || true
    local i=0
    until w reg query "$key" /v pv >/dev/null 2>&1 && [ -n "$(webview2_version)" ]; do
      i=$((i + 1)); [ "$i" -gt 120 ] && break; sleep 5   # 최대 10분
    done
    sleep 5
    wserver -k 2>/dev/null || true   # 설치 프로그램과 업데이트 도우미 종료
    reg_add 'HKCU\Software\Wine' /v Version /t REG_SZ /d win11
    rm -f "$DRIVE_C/windows/temp/MicrosoftEdgeWebview2Setup.exe"
  fi
  ver="$(webview2_version)"
  [ -n "$ver" ] || die "WebView2 런타임을 설치하지 못했어요. 기록: $LOG_DIR/webview2-install.log"
  webview2_freeze
  echo "WebView2 런타임 $ver 준비 완료"
}

cmd_install_plug() { # [--zip <65538.z00>]
  need_prefix
  running_in_prefix 'NexonPlug|NGM64|NGM' && die "넥슨 플러그나 NGM이 실행 중이에요. ./azurctl.sh stop 후 다시 해 주세요."
  local tmp; tmp="$(mktemp -d)"
  if [ "${1:-}" = "--zip" ]; then cp "$2" "$tmp/plug.zip"; else fetch "$PLUG_URL" "$tmp/plug.zip"; fi
  mkdir -p "$DRIVE_C/Nexon/NexonPlug"
  python3 -I "$SCRIPT_DIR/extract_zip.py" "$tmp/plug.zip" "$DRIVE_C/Nexon/NexonPlug"
  rm -rf "$tmp"
  reg_add 'HKLM\Software\Nexon\NexonPlug' /v RootPath /t REG_SZ /d 'C:\Nexon\NexonPlug'
  reg_add 'HKLM\Software\Nexon\NexonPlug' /v Executable /t REG_SZ /d 'C:\Nexon\NexonPlug\NexonPlug.exe'
  local u='HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\NexonPlug'
  reg_add "$u" /v DisplayName /t REG_SZ /d 'NexonPlug'
  reg_add "$u" /v InstallLocation /t REG_SZ /d 'C:\Nexon\NexonPlug'
  reg_add "$u" /v Publisher /t REG_SZ /d 'NEXON Korea Corp.'
  echo "넥슨 플러그 설치 완료"
}

cmd_install_ngm() { # [--src <folder with NGM.exe NGM64.exe SIG.exe>]
  need_prefix
  local dir="$DRIVE_C/ProgramData/Nexon/NGM" f
  mkdir -p "$dir"
  for f in NGM.exe NGM64.exe SIG.exe; do
    if [ "${1:-}" = "--src" ]; then cp "$2/$f" "$dir/$f"; else fetch "$NGM_URL/$f" "$dir/$f"; fi
  done
  for f in NGM.exe NGM64.exe; do
    reg_add 'HKLM\Software\Microsoft\Internet Explorer\MAIN\FeatureControl\FEATURE_BROWSER_EMULATION' /v "$f" /t REG_DWORD /d 11001
    reg_add 'HKLM\Software\Wow6432Node\Microsoft\Internet Explorer\MAIN\FeatureControl\FEATURE_BROWSER_EMULATION' /v "$f" /t REG_DWORD /d 11001
  done
  echo "NGM 설치 완료"
}

cmd_configure() {
  need_prefix
  local root e
  for root in HKCU HKLM; do
    for e in NGM.exe NGM64.exe; do
      reg_add "$root\\Software\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments" /v "$e" /t REG_SZ /d "$GL_FLAGS"
    done
  done
  reg_add 'HKCU\Software\Wine\Mac Driver' /v WindowsFloatWhenInactive /t REG_SZ /d none
  echo "설정 완료"
}

# ---- Wine Mono (.NET) ----
# 게임 안 넥슨 웹 화면(공지, 커뮤니티)을 그리는 cefhelper.exe가 .NET 프로그램이라 Wine Mono가 필요해요.
# 없으면 웹 화면이 하얀 상자로만 나와요. WineHQ 공식 배포본을 받아요.
MONO_VER="10.4.1"
MONO_URL="https://dl.winehq.org/wine/wine-mono/$MONO_VER/wine-mono-$MONO_VER-x86.tar.xz"
MONO_SHA256="a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb"
mono_dir() { echo "$WINE_DIR/share/wine/mono/wine-mono-$MONO_VER"; }
mono_current() { [ -d "$(mono_dir)/lib" ] && [ -f "$DRIVE_C/windows/.azur-mono" ]; }
cmd_install_mono() {
  need_prefix
  if [ ! -d "$(mono_dir)/lib" ]; then
    local tmp; tmp="$(mktemp -d)"
    fetch "$MONO_URL" "$tmp/mono.tar.xz"
    [ "$(sha_of "$tmp/mono.tar.xz")" = "$MONO_SHA256" ] || { rm -rf "$tmp"; die "Wine Mono 파일 체크섬이 맞지 않아요."; }
    mkdir -p "$WINE_DIR/share/wine/mono"
    tar -xJf "$tmp/mono.tar.xz" -C "$WINE_DIR/share/wine/mono"; rm -rf "$tmp"
  fi
  # 같은 폴더의 .cab이 필요해서 Z: 드라이브(맥 경로) 그대로 설치해요.
  local msi="Z:$(printf '%s' "$(mono_dir)/support/winemono-support.msi" | tr '/' '\\')"
  w msiexec /i "$msi" /qn >/dev/null 2>&1 || true
  [ -d "$DRIVE_C/windows/Microsoft.NET/Framework64" ] || die "Wine Mono 지원 패키지를 설치하지 못했어요."
  echo "$MONO_VER" > "$DRIVE_C/windows/.azur-mono"
  echo "Wine Mono $MONO_VER 준비 완료"
}

# ---- 한글 글꼴 ----
# 게임은 윈도우에 깔린 글꼴을 이름으로 찾아요(MiSans, Noto Sans S Chinese, Malgun Gothic).
# Wine 환경에는 이 글꼴들이 없어서 한글이 빠져 보여요. 맥에 원래 있는 한글 글꼴(AppleGothic)을
# 그 이름으로 복사해서 C:\windows\Fonts에 넣어요. 이 맥 안에서만 쓰는 복사본이에요.
FONTS_VERSION=1
KO_FONT_SRC="/System/Library/Fonts/Supplemental/AppleGothic.ttf"
fonts_current() { [ "$(cat "$DRIVE_C/windows/Fonts/.azur-fonts" 2>/dev/null)" = "$FONTS_VERSION" ]; }
cmd_install_fonts() {
  need_prefix
  [ -f "$KO_FONT_SRC" ] || die "맥 한글 글꼴을 찾지 못했어요: $KO_FONT_SRC"
  local fd="$DRIVE_C/windows/Fonts" key='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' entry fam file
  mkdir -p "$fd"
  for entry in "Malgun Gothic|malgun.ttf" "MiSans|MiSans-Regular.ttf" "Noto Sans S Chinese|NotoSansSC-Regular.ttf"; do
    fam="${entry%%|*}"; file="${entry#*|}"
    python3 -I "$SCRIPT_DIR/rename_font.py" "$KO_FONT_SRC" "$fd/$file" "$fam" >/dev/null || die "글꼴을 만들지 못했어요: $fam"
    reg_add "$key" /v "$fam (TrueType)" /t REG_SZ /d "$file"
  done
  local arialuni="/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
  if [ -f "$arialuni" ]; then
    cp "$arialuni" "$fd/ARIALUNI.TTF"
    reg_add "$key" /v "Arial Unicode MS (TrueType)" /t REG_SZ /d ARIALUNI.TTF
  fi
  echo "$FONTS_VERSION" > "$fd/.azur-fonts"
  echo "한글 글꼴 설치 완료"
}

cmd_link_game() { # <이미 받은 AzurPromilia 폴더>  다시 받지 않고 가져와요
  # 링크로 연결하면 한쪽에서 게임을 지울 때 다른 쪽 게임까지 지워져요. 그래서 APFS 복제(cp -c)로
  # 따로 된 사본을 만들어요. 복제는 거의 바로 끝나고, 바뀐 부분이 생기기 전까지 추가 공간도 거의 안 써요.
  need_prefix
  [ -f "${1:-}/AzurPromilia.exe" ] || die "AzurPromilia.exe가 있는 폴더를 지정해 주세요."
  local dest="$DRIVE_C/Nexon/AzurPromilia"
  if [ -L "$dest" ]; then rm "$dest"; fi
  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then die "이미 게임 폴더가 있어요: $dest"; fi
  rmdir "$dest" 2>/dev/null || true
  mkdir -p "$DRIVE_C/Nexon"
  echo "게임 복제 중 (APFS 복제라 추가 공간은 거의 안 써요)…"
  cp -cR "$1" "$dest" || { rm -rf "$dest"; die "게임을 복제하지 못했어요. 같은 APFS 디스크인지 확인해 주세요."; }
  echo "가져왔어요: C:\\Nexon\\AzurPromilia"
}

migrate_game_link() { # 0.3.1까지 만든 링크를 따로 된 사본으로 바꿔요 (한쪽에서 지우면 둘 다 지워지는 문제)
  local dest="$DRIVE_C/Nexon/AzurPromilia" target
  [ -L "$dest" ] || return 0
  target="$(readlink "$dest")"
  rm "$dest"
  if [ -f "$target/AzurPromilia.exe" ]; then
    echo "게임 링크를 따로 된 사본으로 바꾸는 중…"
    cp -cR "$target" "$dest" || mkdir -p "$dest"
  else
    mkdir -p "$dest"   # 링크가 끊어져 있었으면 빈 폴더로 (넥슨 플러그에서 다시 설치)
  fi
}

game_install_key() { # <system.reg>  NGM이 게임 설치 위치를 기억하는 키 이름 (2887_<태그>_live_<번호>의 base64)
  { grep -F -B3 '"RootPath"="C:\\Nexon\\AzurPromilia"' "$1" 2>/dev/null || true; } \
    | sed -nE 's/^\[Software\\\\Wow6432Node\\\\Nexon\\\\([A-Za-z0-9+=]+)\].*/\1/p' | tail -1
}

register_game_install() { # <키 이름> [2887.dat]  NGM이 "설치됨"으로 알도록 기록해요.
  # 이 기록이 없으면 넥슨 플러그에서 설치를 누를 때 NGM이 게임 폴더를 비우고 처음부터 받아요.
  local key="$1" dat="${2:-}"
  reg_add "HKLM\\Software\\Wow6432Node\\Nexon\\$key" /v RootPath /t REG_SZ /d 'C:\Nexon\AzurPromilia'
  local u="HKLM\\Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$key"
  reg_add "$u" /v DisplayName /t REG_SZ /d '아주르 프로밀리아'
  reg_add "$u" /v DisplayIcon /t REG_SZ /d 'C:\Nexon\AzurPromilia\AzurPromilia.exe'
  reg_add "$u" /v InstallLocation /t REG_SZ /d 'C:\Nexon\AzurPromilia'
  reg_add "$u" /v Publisher /t REG_SZ /d 'NEXON Korea Corp.'
  reg_add "$u" /v UninstallString /t REG_SZ /d '"C:\Nexon\AzurPromilia\NGM64.exe" -mode:uninstall -game:2887 -service:0 -use_local_dll'
  reg_add 'HKLM\Software\Wow6432Node\Nexon\NGM' /v NxDownload /t REG_SZ /d 'C:\Nexon\Download'
  mkdir -p "$DRIVE_C/ProgramData/Nexon/NGM" "$DRIVE_C/Nexon/Download"
  [ -n "$dat" ] && [ -f "$dat" ] && cp "$dat" "$DRIVE_C/ProgramData/Nexon/NGM/2887.dat"
  return 0
}

cmd_import_crossover() { # [보틀 이름]  CrossOver 보틀에 받아 둔 게임을 다시 받지 않고 가져와요 (APFS 복제)
  need_prefix
  local bottle="${1:-Azur Promilia}"
  local b="$HOME/Library/Application Support/CrossOver/Bottles/$bottle"
  [ -f "$b/drive_c/Nexon/AzurPromilia/AzurPromilia.exe" ] || die "보틀 '$bottle'에 설치된 게임이 없어요."
  running_in_prefix 'NexonPlug|NGM64|NGM' && die "넥슨 플러그가 실행 중이에요. ./azurctl.sh stop 후 다시 해 주세요."
  local key; key="$(game_install_key "$b/system.reg")"
  [ -n "$key" ] || die "보틀에서 게임 설치 정보를 찾지 못했어요."
  cmd_link_game "$b/drive_c/Nexon/AzurPromilia"
  register_game_install "$key" "$b/drive_c/ProgramData/Nexon/NGM/2887.dat"
  echo "CrossOver 보틀 '$bottle'의 게임을 가져왔어요 (설치 정보 키: $key)."
}

# ---- 설정 (settings.conf, key=value) ----
SETTINGS="$APP_HOME/settings.conf"
SETTING_KEYS="metal_hud retina left_cmd_ctrl game_hangul custom_resolution width height custom_fps fps"
setting_default() {
  case "$1" in width) echo 1920 ;; height) echo 1200 ;; fps) echo 60 ;; game_hangul) echo 1 ;; *) echo 0 ;; esac
}
setting() { # key
  local v; v="$(grep -E "^$1=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  echo "${v:-$(setting_default "$1")}"
}
cmd_settings() { local k; for k in $SETTING_KEYS; do echo "$k=$(setting "$k")"; done; }
cmd_get() { setting "${1:?설정 이름}"; }
cmd_set() { # key value
  local k="${1:?설정 이름}" v="${2:?값}"
  case "$k" in
    metal_hud|retina|left_cmd_ctrl|game_hangul|custom_resolution|custom_fps) [[ "$v" =~ ^[01]$ ]] || die "$k 는 0 또는 1이에요." ;;
    width|height) [[ "$v" =~ ^[0-9]{3,5}$ ]] && [ "$v" -ge 640 ] || die "$k 는 640 이상의 숫자예요." ;;
    fps) [[ "$v" =~ ^[0-9]{2,3}$ ]] && [ "$v" -ge 30 ] || die "fps 는 30 이상의 숫자예요." ;;
    *) die "알 수 없는 설정: $k" ;;
  esac
  mkdir -p "$APP_HOME"; touch "$SETTINGS"
  { grep -vE "^$k=" "$SETTINGS" || true; echo "$k=$v"; } > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "$k=$v"
}
yn() { [ "$1" = 1 ] && echo y || echo n; }

disable_nexon_launcher_service() {
  # NGM은 게임을 켤 때 "Nexon Launcher" 서비스를 설치하고 시작을 시도해요. Wine에서는 이 서비스가
  # 끝내 시작되지 않아서 NGM이 한참 기다리고, 그동안 넥슨 플러그가 "게임 실행에 실패했습니다"를 띄워요.
  # 서비스를 꺼 두면 NGM이 기다리지 않고 바로 게임을 켜요.
  local svc='HKLM\System\CurrentControlSet\Services\Nexon Launcher'
  if w reg query "$svc" >/dev/null 2>&1; then
    reg_add "$svc" /v Start /t REG_DWORD /d 4
  fi
  return 0
}

apply_settings() { # 넥슨 플러그를 켜기 직전에 적용해요 (게임은 넥슨 플러그가 켜요)
  disable_nexon_launcher_service
  reg_add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d "$(yn "$(setting retina)")"
  reg_add 'HKCU\Software\Wine\Mac Driver' /v LeftCommandIsCtrl /t REG_SZ /d "$(yn "$(setting left_cmd_ctrl)")"
  # 게임은 자기 창의 IME를 꺼 둬서 맥 한글 입력기가 조합을 못 해요. 런타임(p2 이상)의 ImeFallback이
  # 게임 창의 키를 맥 입력기에 먼저 보내고 완성된 글자를 게임에 넘겨요. 넥슨 플러그에는 영향이 없어요.
  reg_add 'HKCU\Software\Wine\AppDefaults\AzurPromilia.exe\Mac Driver' /v ImeFallback /t REG_SZ /d "$(yn "$(setting game_hangul)")"
  local k='HKCU\Software\manjuu\AzurPromilia'   # 게임(Unity)이 화면 설정을 저장하는 곳
  if [ "$(setting custom_resolution)" = 1 ]; then
    reg_add "$k" /v 'Screenmanager Resolution Width_h182942802' /t REG_DWORD /d "$(setting width)"
    reg_add "$k" /v 'Screenmanager Resolution Height_h2627697771' /t REG_DWORD /d "$(setting height)"
    reg_add "$k" /v 'Screenmanager Resolution Use Native_h1405027254' /t REG_DWORD /d 0
  fi
  if [ "$(setting custom_fps)" = 1 ]; then
    reg_add "$k" /v 'Screenmanager RefreshRate Numerator_h3473131500' /t REG_DWORD /d "$(setting fps)"
    reg_add "$k" /v 'Screenmanager RefreshRate Denominator_h3597814599' /t REG_DWORD /d 1
  fi
}

cmd_plug() {
  need_prefix
  [ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] || die "넥슨 플러그가 없어요. 먼저 ./azurctl.sh setup"
  mkdir -p "$LOG_DIR"
  fonts_current || cmd_install_fonts >/dev/null
  mono_current || cmd_install_mono >/dev/null
  migrate_game_link
  apply_settings
  local hud=0 dxmt_config=""
  [ "$(setting metal_hud)" = 1 ] && hud=1
  [ "$(setting custom_fps)" = 1 ] && dxmt_config="d3d11.preferredMaxFrameRate=$(setting fps);"
  # 넥슨 플러그 -> NGM -> 게임 순서로 켜지면서 이 환경 변수가 게임까지 이어져요.
  # shellcheck disable=SC2086
  nohup env WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1 WINEESYNC=1 DXMT_LOG_PATH="$LOG_DIR" \
    DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:/usr/lib" MTL_HUD_ENABLED="$hud" DXMT_CONFIG="$dxmt_config" DXMT_LOG_LEVEL="${DXMT_LOG_LEVEL:-error}" \
    "$WINE_DIR/bin/wine" 'C:\Nexon\NexonPlug\NexonPlug.exe' $GL_FLAGS >"$LOG_DIR/nexonplug.log" 2>&1 &
  echo "넥슨 플러그를 켰어요."
}

cmd_running() { # 이 런처의 wineserver가 떠 있으면 yes (경로가 .../wine/lib/wine/../../bin/wineserver 처럼 보여요)
  ps -axo command= | grep -F "$WINE_DIR/" | grep -q 'wineserver' && echo yes || echo no
}

cmd_game_direct() { # 런처 없이 게임 실행 파일만 켜 보는 테스트 (로그인은 안 돼요)
  need_prefix
  mkdir -p "$LOG_DIR"
  w 'C:\Nexon\AzurPromilia\AzurPromilia.exe' >"$LOG_DIR/game-direct.log" 2>&1 || true
}

cmd_stop()    { [ -d "$PREFIX" ] && wserver -k 2>/dev/null || true; echo "종료했어요."; }
cmd_winecfg() { need_prefix; w winecfg; }
cmd_shell()   { need_prefix; echo "WINEPREFIX=$PREFIX  wine=$WINE_DIR/bin/wine"; }

# ---- 다운로드 상태 ----
# 게임 다운로드는 NGM이 해요. Wine에서는 가끔 중간에 멈추고 NGM이 꺼져서, 넥슨 플러그에서
# 이어받기를 다시 눌러야 해요. 런처 창이 이걸 알아채서 안내할 수 있게 상태를 한 줄로 알려줘요.
#   state=none|downloading|stalled|stopped|installed  game_gb=..  pieces=..
cmd_download_status() {
  local game="$DRIVE_C/Nexon/AzurPromilia" pend="$DRIVE_C/Nexon/Download/2887/install"
  local gb pieces state ngm=no stamp="$APP_HOME/.download-progress"
  pgrep -f 'NGM64\.exe' >/dev/null && ngm=yes
  gb="$(du -sk "$game" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')"; gb="${gb:-0.0}"
  pieces="$(ls "$pend" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  if [ "$ngm" = yes ]; then
    # 2분 넘게 크기가 그대로면 멈춘 것으로 봐요
    local now size last_size last_time
    now=$(date +%s); size="$(du -sk "$DRIVE_C/Nexon" 2>/dev/null | awk '{print $1}')"
    [ -f "$stamp" ] && read -r last_size last_time < "$stamp"
    if [ "${last_size:-}" != "$size" ]; then echo "$size $now" > "$stamp"; state=downloading
    elif [ $((now - ${last_time:-$now})) -gt 120 ]; then state=stalled
    else state=downloading; fi
  elif [ -n "$pieces" ]; then
    state=stopped
  elif [ -f "$game/AzurPromilia.exe" ]; then
    state=installed
  else
    state=none
  fi
  echo "state=$state game_gb=$gb pieces=${pieces:-none}"
}

# ---- 문제 보고 ----
# 상태와 로그 끝부분을 모아요. 로그인 토큰, 이메일, 맥 사용자 이름, 넥슨 회원 번호는 가려요.
redact() {
  sed -E -e 's/(NP[0-9]+:auth:|passport:)[^ "\x27}]*/\1[가림]/g' \
         -e 's/-token:[^ ]*/-token:[가림]/g' \
         -e 's/("[A-Za-z_]*([Tt]oken|[Tt]icket|[Ss]ession[Ii]d|[Pp]assport)"[[:space:]]*:[[:space:]]*")[^"]*/\1[가림]/g' \
         -e 's/(ias:gt:|NP[0-9]+:)[^ "}]*/\1[가림]/g' \
         -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[이메일 가림]/g' \
         -e "s#$HOME#~#g" -e "s#/Users/$USER#~#g" \
         -e 's/(user_sn|UID|uid)([":= ]+)[0-9]{5,}/\1\2[가림]/g'
}
cmd_report() {
  {
    echo "### 아주르 프로밀리아 런처 문제 보고"
    echo "- 런처 버전: ${AZUR_APP_VERSION:-알 수 없음}"
    echo "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "- 맥: $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string) / 메모리 $(( $(sysctl -n hw.memsize) / 1073741824 ))GB"
    echo "- 여유 공간: $(df -h "$HOME" | awk 'NR==2{print $4}')"
    echo "- 런타임: $(cat "$WINE_DIR/.azur-runtime" 2>/dev/null || echo 없음)"
    echo "- Wine Mono: $(cat "$DRIVE_C/windows/.azur-mono" 2>/dev/null || echo 없음)  WebView2: $(webview2_version 2>/dev/null || echo 없음)"
    echo "- 실행 중: $(cmd_running)  다운로드: $(cmd_download_status 2>/dev/null)"
    echo "- 설정: $(cmd_settings 2>/dev/null | tr '\n' ' ')"
    echo
    echo '```'
    cmd_status 2>&1
    echo '```'
    local f
    for f in "$LOG_DIR/setup.log" "$LOG_DIR/nexonplug.log" "$DRIVE_C/ProgramData/Nexon/NGM/NGM.log" \
             "$DRIVE_C/users/crossover/AppData/Roaming/Nexon/nxDownloader/config/service.log"; do
      [ -f "$f" ] || continue
      echo; echo "#### $(basename "$f") (마지막 30줄)"; echo '```'
      tail -30 "$f" | tr -d '\r' | grep -v 'VK_\|^\s*$' | cut -c1-240
      echo '```'
    done
    local pl; pl="$(find "$DRIVE_C/users" -path '*manjuu/AzurPromilia/Player.log' 2>/dev/null | head -1)"
    if [ -n "$pl" ]; then
      echo; echo "#### 게임 로그 오류 (마지막 25개)"; echo '```'
      grep -E 'Exception|\[Error\]|error|Crash' "$pl" | tail -25 | cut -c1-240
      echo '```'
    fi
  } | redact
}

# ---- 지우기 ----
#   uninstall --keep-game  런처 데이터는 지우고 받은 게임은 남겨요 (다시 준비할 때 그대로 써요)
#   uninstall --all        게임까지 모두 지워요
KEEP_DIR="$APP_HOME/kept-game"
cmd_uninstall() {
  local mode="${1:-}"
  [ "$mode" = --keep-game ] || [ "$mode" = --all ] || die "사용법: uninstall --keep-game | --all"
  [ -d "$PREFIX" ] && wserver -k 2>/dev/null || true
  sleep 1
  if [ "$mode" = --keep-game ] && [ -f "$DRIVE_C/Nexon/AzurPromilia/AzurPromilia.exe" ]; then
    mkdir -p "$KEEP_DIR"; rm -rf "$KEEP_DIR/AzurPromilia"
    game_install_key "$PREFIX/system.reg" > "$KEEP_DIR/install-key.txt"
    cp "$DRIVE_C/ProgramData/Nexon/NGM/2887.dat" "$KEEP_DIR/2887.dat" 2>/dev/null || true
    mv "$DRIVE_C/Nexon/AzurPromilia" "$KEEP_DIR/AzurPromilia"
  fi
  local item
  for item in "$APP_HOME"/* "$APP_HOME"/.[!.]*; do
    [ -e "$item" ] || continue
    [ "$mode" = --keep-game ] && [ "$item" = "$KEEP_DIR" ] && continue
    rm -rf "$item"
  done
  [ "$mode" = --all ] && rm -rf "$APP_HOME"
  echo "지웠어요.$([ "$mode" = --keep-game ] && [ -d "$KEEP_DIR/AzurPromilia" ] && echo " 게임은 남겨 뒀어요. 다시 준비하면 그대로 써요.")"
}

restore_kept_game() {
  [ -f "$KEEP_DIR/AzurPromilia/AzurPromilia.exe" ] || return 0
  [ -e "$DRIVE_C/Nexon/AzurPromilia" ] && [ -n "$(ls -A "$DRIVE_C/Nexon/AzurPromilia" 2>/dev/null)" ] && return 0
  local key; key="$(cat "$KEEP_DIR/install-key.txt" 2>/dev/null)"
  if [ -z "$key" ]; then
    warn "남겨 둔 게임의 설치 기록이 없어서 그대로 둬요: $KEEP_DIR (넥슨 플러그에서 새로 설치하면 폴더를 비우고 받아요)"
    return 0
  fi
  register_game_install "$key" "$KEEP_DIR/2887.dat"   # 기록 먼저 (실패하면 게임은 그대로 남아요)
  rmdir "$DRIVE_C/Nexon/AzurPromilia" 2>/dev/null || true
  mkdir -p "$DRIVE_C/Nexon"
  mv "$KEEP_DIR/AzurPromilia" "$DRIVE_C/Nexon/AzurPromilia"
  rm -rf "$KEEP_DIR"
  echo "남겨 둔 게임을 다시 연결했어요. 넥슨 플러그에서 바로 게임시작을 누르면 돼요."
}

cmd_status() {
  printf '%-14s %s\n' "앱 폴더" "$APP_HOME"
  printf '%-14s %s\n' "Wine" "$([ -x "$WINE_DIR/bin/wine" ] && w --version 2>/dev/null || echo 없음)"
  printf '%-14s %s\n' "DXMT" "$([ -f "$WINE_DIR/lib/wine/x86_64-unix/winemetal.so" ] && echo 설치됨 || echo 없음)"
  printf '%-14s %s\n' "Wine 환경" "$([ -d "$DRIVE_C" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "WebView2" "$([ -d "$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView/Application" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "넥슨 플러그" "$([ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "NGM" "$([ -f "$DRIVE_C/ProgramData/Nexon/NGM/NGM64.exe" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "게임" "$([ -f "$DRIVE_C/Nexon/AzurPromilia/AzurPromilia.exe" ] && echo 있음 || echo 없음)"
}

cmd_status_code() { # 앱이 쓰는 한 단어 상태: ready | setup
  if runtime_current \
     && [ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] && [ -f "$DRIVE_C/ProgramData/Nexon/NGM/NGM64.exe" ]; then
    echo ready
  else
    echo setup
  fi
}

# 이 맥에 이미 있는 재료를 찾아서 setup 옵션으로 출력해요 (다운로드를 줄이려고).
#  - CrossOver "Azur Promilia" 보틀의 WebView2 런타임과 이미 받은 게임
cmd_detect_sources() {
  local b="$HOME/Library/Application Support/CrossOver/Bottles/Azur Promilia/drive_c" out=""
  if [ -d "$b/Program Files (x86)/Microsoft/EdgeWebView/Application" ]; then
    out+="--webview2-from $(printf '%q' "$b/Program Files (x86)/Microsoft/EdgeWebView") "
  fi
  if [ -f "$b/Nexon/AzurPromilia/AzurPromilia.exe" ]; then
    out+="--import-crossover $(printf '%q' "Azur Promilia") "
  fi
  echo "$out"
}

cmd_setup() { # [--runtime-from TAR.XZ] [--webview2-from DIR] [--import-crossover BOTTLE]
  local runtime_from="" wv2_from="" import_bottle=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime-from) runtime_from="$2"; shift 2 ;;
      --webview2-from) wv2_from="$2"; shift 2 ;;
      --import-crossover) import_bottle="$2"; shift 2 ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
  done
  command -v python3 >/dev/null || die "python3가 필요해요. 터미널에서 xcode-select --install"
  if ! runtime_current; then
    say "1/6 Wine + DXMT 런타임 설치 ($RUNTIME_NAME)"
    [ -d "$PREFIX" ] && wserver -k 2>/dev/null || true   # 예전 Wine이 돌고 있으면 먼저 종료
    if [ -n "$runtime_from" ]; then cmd_install_runtime --from "$runtime_from"; else cmd_install_runtime; fi
  fi
  say "2/6 Wine 환경 준비"; cmd_init_prefix; mono_current || cmd_install_mono
  if [ -z "$(webview2_version)" ]; then
    say "3/6 WebView2 런타임 (NGM에 필요)"
    if [ -n "$wv2_from" ]; then cmd_install_webview2 --from "$wv2_from"; else cmd_install_webview2; fi
  fi
  say "4/6 넥슨 플러그 설치"; cmd_install_plug
  say "5/6 NGM 설치"; cmd_install_ngm
  say "6/6 호환 설정"; cmd_configure; cmd_install_fonts
  restore_kept_game
  if [ -n "$import_bottle" ] && [ ! -e "$DRIVE_C/Nexon/AzurPromilia" ]; then
    say "CrossOver에 받아 둔 게임 가져오기"; cmd_import_crossover "$import_bottle"
  fi
  wserver -w 2>/dev/null || true
  say "준비 완료. ./azurctl.sh plug 로 넥슨 플러그를 켜세요."
}

sub="${1:-status}"; shift || true
case "$sub" in
  setup|install-runtime|init-prefix|install-webview2|install-plug|install-ngm|configure|link-game|import-crossover|plug|game-direct|stop|status|status-code|detect-sources|winecfg|shell|settings|get|set|running|install-fonts|install-mono|download-status|report|uninstall)
    "cmd_${sub//-/_}" "$@" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
