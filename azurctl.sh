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
RUNTIME_TAG="runtime-cx26.3.0-dxmt0.80"
RUNTIME_NAME="azur-runtime-cx26.3.0-dxmt0.80"
RUNTIME_URL="https://github.com/SELCORE/azur-promilia-launcher/releases/download/$RUNTIME_TAG/$RUNTIME_NAME.tar.xz"
RUNTIME_SHA256="15866cf9ca94040535d8371c53ca2f1b6b9194e0de232d642c3dad069519b1cf"

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

cmd_link_game() { # <existing AzurPromilia folder>  (다른 곳에 이미 받은 게임을 복사 없이 연결)
  need_prefix
  [ -f "${1:-}/AzurPromilia.exe" ] || die "AzurPromilia.exe가 있는 폴더를 지정해 주세요."
  local dest="$DRIVE_C/Nexon/AzurPromilia"
  [ -e "$dest" ] && [ ! -L "$dest" ] && die "이미 게임 폴더가 있어요: $dest"
  mkdir -p "$DRIVE_C/Nexon"; rm -f "$dest"; ln -s "$1" "$dest"
  echo "연결했어요: C:\\Nexon\\AzurPromilia -> $1"
}

cmd_import_crossover() { # [보틀 이름]  CrossOver 보틀에 받아 둔 게임을 다시 받지 않고 가져와요 (복사 없이 연결)
  need_prefix
  local bottle="${1:-Azur Promilia}"
  local b="$HOME/Library/Application Support/CrossOver/Bottles/$bottle"
  [ -f "$b/drive_c/Nexon/AzurPromilia/AzurPromilia.exe" ] || die "보틀 '$bottle'에 설치된 게임이 없어요."
  running_in_prefix 'NexonPlug|NGM64|NGM' && die "넥슨 플러그가 실행 중이에요. ./azurctl.sh stop 후 다시 해 주세요."
  cmd_link_game "$b/drive_c/Nexon/AzurPromilia"
  # NGM이 게임 설치 위치를 기억하는 키 이름(예: 2887_<태그>_live_<번호>의 base64)을 보틀에서 그대로 가져와요.
  local key
  key="$( { grep -F -B3 '"RootPath"="C:\\Nexon\\AzurPromilia"' "$b/system.reg" || true; } \
        | sed -nE 's/^\[Software\\\\Wow6432Node\\\\Nexon\\\\([A-Za-z0-9+=]+)\].*/\1/p' | tail -1)"
  [ -n "$key" ] || die "보틀에서 게임 설치 정보를 찾지 못했어요."
  reg_add "HKLM\\Software\\Wow6432Node\\Nexon\\$key" /v RootPath /t REG_SZ /d 'C:\Nexon\AzurPromilia'
  local u="HKLM\\Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$key"
  reg_add "$u" /v DisplayName /t REG_SZ /d '아주르 프로밀리아'
  reg_add "$u" /v DisplayIcon /t REG_SZ /d 'C:\Nexon\AzurPromilia\AzurPromilia.exe'
  reg_add "$u" /v InstallLocation /t REG_SZ /d 'C:\Nexon\AzurPromilia'
  reg_add "$u" /v Publisher /t REG_SZ /d 'NEXON Korea Corp.'
  reg_add "$u" /v UninstallString /t REG_SZ /d '"C:\Nexon\AzurPromilia\NGM64.exe" -mode:uninstall -game:2887 -service:0 -use_local_dll'
  reg_add 'HKLM\Software\Wow6432Node\Nexon\NGM' /v NxDownload /t REG_SZ /d 'C:\Nexon\Download'
  mkdir -p "$DRIVE_C/ProgramData/Nexon/NGM" "$DRIVE_C/Nexon/Download"
  [ -f "$b/drive_c/ProgramData/Nexon/NGM/2887.dat" ] && cp "$b/drive_c/ProgramData/Nexon/NGM/2887.dat" "$DRIVE_C/ProgramData/Nexon/NGM/2887.dat"
  echo "CrossOver 보틀 '$bottle'의 게임을 가져왔어요 (설치 정보 키: $key)."
}

# ---- 설정 (settings.conf, key=value) ----
SETTINGS="$APP_HOME/settings.conf"
SETTING_KEYS="metal_hud retina left_cmd_ctrl custom_resolution width height custom_fps fps"
setting_default() {
  case "$1" in width) echo 1920 ;; height) echo 1200 ;; fps) echo 60 ;; *) echo 0 ;; esac
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
    metal_hud|retina|left_cmd_ctrl|custom_resolution|custom_fps) [[ "$v" =~ ^[01]$ ]] || die "$k 는 0 또는 1이에요." ;;
    width|height) [[ "$v" =~ ^[0-9]{3,5}$ ]] && [ "$v" -ge 640 ] || die "$k 는 640 이상의 숫자예요." ;;
    fps) [[ "$v" =~ ^[0-9]{2,3}$ ]] && [ "$v" -ge 30 ] || die "fps 는 30 이상의 숫자예요." ;;
    *) die "알 수 없는 설정: $k" ;;
  esac
  mkdir -p "$APP_HOME"; touch "$SETTINGS"
  { grep -vE "^$k=" "$SETTINGS" || true; echo "$k=$v"; } > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "$k=$v"
}
yn() { [ "$1" = 1 ] && echo y || echo n; }

apply_settings() { # 넥슨 플러그를 켜기 직전에 적용해요 (게임은 넥슨 플러그가 켜요)
  reg_add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d "$(yn "$(setting retina)")"
  reg_add 'HKCU\Software\Wine\Mac Driver' /v LeftCommandIsCtrl /t REG_SZ /d "$(yn "$(setting left_cmd_ctrl)")"
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
  apply_settings
  local hud=0 dxmt_config=""
  [ "$(setting metal_hud)" = 1 ] && hud=1
  [ "$(setting custom_fps)" = 1 ] && dxmt_config="d3d11.preferredMaxFrameRate=$(setting fps);"
  # 넥슨 플러그 -> NGM -> 게임 순서로 켜지면서 이 환경 변수가 게임까지 이어져요.
  # shellcheck disable=SC2086
  nohup env WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1 WINEESYNC=1 DXMT_LOG_PATH="$LOG_DIR" \
    DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:/usr/lib" MTL_HUD_ENABLED="$hud" DXMT_CONFIG="$dxmt_config" \
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
  say "2/6 Wine 환경 준비"; cmd_init_prefix
  if [ -z "$(webview2_version)" ]; then
    say "3/6 WebView2 런타임 (NGM에 필요)"
    if [ -n "$wv2_from" ]; then cmd_install_webview2 --from "$wv2_from"; else cmd_install_webview2; fi
  fi
  say "4/6 넥슨 플러그 설치"; cmd_install_plug
  say "5/6 NGM 설치"; cmd_install_ngm
  say "6/6 호환 설정"; cmd_configure
  if [ -n "$import_bottle" ] && [ ! -e "$DRIVE_C/Nexon/AzurPromilia" ]; then
    say "CrossOver에 받아 둔 게임 가져오기"; cmd_import_crossover "$import_bottle"
  fi
  wserver -w 2>/dev/null || true
  say "준비 완료. ./azurctl.sh plug 로 넥슨 플러그를 켜세요."
}

sub="${1:-status}"; shift || true
case "$sub" in
  setup|install-runtime|init-prefix|install-webview2|install-plug|install-ngm|configure|link-game|import-crossover|plug|game-direct|stop|status|status-code|detect-sources|winecfg|shell|settings|get|set|running)
    "cmd_${sub//-/_}" "$@" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
