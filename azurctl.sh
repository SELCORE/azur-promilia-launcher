#!/bin/bash
# azurctl: CrossOver 없이 무료 Wine + DXMT로 넥슨 플러그와 아주르 프로밀리아를 돌리는 런처의 핵심 스크립트.
#
#   ./azurctl.sh setup            Wine, DXMT, 넥슨 플러그, NGM을 설치하고 설정해요 (처음 한 번)
#   ./azurctl.sh plug             넥슨 플러그를 켜요
#   ./azurctl.sh stop             이 런처의 Wine 프로세스를 모두 종료해요
#   ./azurctl.sh status           설치 상태를 보여줘요
#
# 개별 단계: install-wine, install-dxmt, init-prefix, install-webview2, install-plug, install-ngm,
#           configure, link-game, import-crossover, game-direct, winecfg, shell
# 내려받는 파일은 모두 원래 배포처(넥슨 공식 서버, Yaagl 프로젝트의 GitHub 릴리스)에서 받아요.
set -euo pipefail

APP_HOME="${AZUR_HOME:-$HOME/Library/Application Support/Azur Promilia Launcher}"
WINE_DIR="$APP_HOME/wine"
PREFIX="$APP_HOME/prefix"
LOG_DIR="$APP_HOME/logs"
DRIVE_C="$PREFIX/drive_c"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Wine (CodeWeavers의 공개 소스로 만든 빌드)와 DXMT(DirectX 11 -> Metal). Yaagl 프로젝트가 배포하는 빌드예요.
WINE_URL="https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
WINE_SHA256="89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35"
DXMT_URL="https://github.com/yaagl/anime-game-wine/releases/download/dxmt-654f547/dxmt-654f547ffab4e0c395ee368aad52bb4586b04576.zip"
DXMT_COMMIT="654f547ffab4e0c395ee368aad52bb4586b04576"

PLUG_URL="https://platform.nexon.com/NexonPlug/Install/InstallData/65538.z00"
NGM_URL="https://platform.nexon.com/NGM/Bin"
UA="Mozilla/5.0"
# Wine에서는 Chromium 계열(넥슨 플러그, WebView2) 화면의 GPU 렌더링이 검게 나와서 소프트웨어 렌더링을 써요.
GL_FLAGS="--use-gl=swiftshader --use-angle=swiftshader --in-process-gpu"
DXMT_DLLS="d3d10core.dll d3d11.dll dxgi.dll"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '주의: %s\n' "$*" >&2; }
die()  { printf '오류: %s\n' "$*" >&2; exit 1; }

w() {
  WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1 WINEESYNC=1 \
    DXMT_LOG_PATH="$LOG_DIR" "$WINE_DIR/bin/wine" "$@"
}
wserver() { WINEPREFIX="$PREFIX" "$WINE_DIR/bin/wineserver" "$@"; }
reg_add() { w reg add "$@" /f >/dev/null 2>&1 || die "레지스트리 설정 실패: $*"; }
need_wine()   { [ -x "$WINE_DIR/bin/wine" ] || die "Wine이 없어요. 먼저 ./azurctl.sh install-wine"; }
need_prefix() { need_wine; [ -d "$DRIVE_C" ] || die "Wine 환경이 없어요. 먼저 ./azurctl.sh init-prefix"; }
running_in_prefix() { w tasklist 2>/dev/null | grep -qiE "^($1)\.exe"; }

fetch() { # url dest
  echo "받는 중: $1"
  curl -fL -# --retry 3 -A "$UA" -o "$2" "$1"
}

cmd_install_wine() { # [--from <wine dir>]
  mkdir -p "$APP_HOME"
  rm -rf "$WINE_DIR.new"
  if [ "${1:-}" = "--from" ]; then
    [ -x "$2/bin/wine" ] || die "Wine 폴더가 아니에요: $2"
    cp -cR "$2" "$WINE_DIR.new" 2>/dev/null || cp -R "$2" "$WINE_DIR.new"
  else
    local tmp; tmp="$(mktemp -d)"
    fetch "$WINE_URL" "$tmp/wine.tar.xz"
    echo "$WINE_SHA256  $tmp/wine.tar.xz" | shasum -a 256 -c - >/dev/null || die "Wine 파일 체크섬이 맞지 않아요."
    mkdir -p "$tmp/x" && tar -xJf "$tmp/wine.tar.xz" -C "$tmp/x"
    local found; found="$(dirname "$(dirname "$(find "$tmp/x" -path '*/bin/wineserver' -type f | head -1)")")"
    [ -x "$found/bin/wine" ] || die "압축 안에서 Wine을 찾지 못했어요."
    mv "$found" "$WINE_DIR.new"; rm -rf "$tmp"
  fi
  xattr -dr com.apple.quarantine "$WINE_DIR.new" 2>/dev/null || true
  rm -rf "$WINE_DIR"; mv "$WINE_DIR.new" "$WINE_DIR"
  echo "Wine: $("$WINE_DIR/bin/wine" --version)"
}

cmd_install_dxmt() { # [--from <folder with d3d11.dll dxgi.dll ... winemetal.so>]
  need_wine
  local src tmp=""
  if [ "${1:-}" = "--from" ]; then
    src="$2"
  else
    tmp="$(mktemp -d)"
    fetch "$DXMT_URL" "$tmp/dxmt.zip"
    (cd "$tmp" && unzip -q dxmt.zip && tar -xzf "dxmt-$DXMT_COMMIT.tar.gz")
    src="$tmp/flat"; mkdir -p "$src"
    cp "$tmp/$DXMT_COMMIT/x86_64-windows/"* "$tmp/$DXMT_COMMIT/x86_64-unix/"* "$src/"
  fi
  local win="$WINE_DIR/lib/wine/x86_64-windows" unix="$WINE_DIR/lib/wine/x86_64-unix"
  for f in $DXMT_DLLS winemetal.dll winemetal.so; do [ -f "$src/$f" ] || die "DXMT 파일이 없어요: $src/$f"; done
  for f in $DXMT_DLLS; do
    [ -f "$win/$f.wined3d" ] || cp "$win/$f" "$win/$f.wined3d"   # 원래 Wine 파일 보관
    cp "$src/$f" "$win/$f"
  done
  cp "$src/winemetal.dll" "$win/winemetal.dll"
  cp "$src/winemetal.so" "$unix/winemetal.so"
  if [ -d "$DRIVE_C/windows/system32" ]; then cp "$src/winemetal.dll" "$DRIVE_C/windows/system32/winemetal.dll"; fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  echo "DXMT 설치 완료"
}

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

cmd_install_webview2() { # --from <EdgeWebView folder, e.g. a CrossOver bottle's "Program Files (x86)/Microsoft/EdgeWebView">
  need_prefix
  [ "${1:-}" = "--from" ] || die "사용법: install-webview2 --from <EdgeWebView 폴더>"
  local src="$2" ver
  ver="$(ls "$src/Application" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [ -n "$ver" ] || die "WebView2 런타임 버전 폴더를 찾지 못했어요: $src/Application"
  local dest="$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView"
  mkdir -p "$(dirname "$dest")"; rm -rf "$dest"
  cp -cR "$src" "$dest" 2>/dev/null || cp -R "$src" "$dest"
  local key='HKLM\Software\Wow6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  reg_add "$key" /v location /t REG_SZ /d 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application'
  reg_add "$key" /v name /t REG_SZ /d 'Microsoft Edge WebView2 Runtime'
  reg_add "$key" /v pv /t REG_SZ /d "$ver"
  echo "WebView2 런타임 $ver 설치 완료"
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

cmd_plug() {
  need_prefix
  [ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] || die "넥슨 플러그가 없어요. 먼저 ./azurctl.sh setup"
  mkdir -p "$LOG_DIR"
  # shellcheck disable=SC2086
  nohup env WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1 WINEESYNC=1 DXMT_LOG_PATH="$LOG_DIR" \
    "$WINE_DIR/bin/wine" 'C:\Nexon\NexonPlug\NexonPlug.exe' $GL_FLAGS >"$LOG_DIR/nexonplug.log" 2>&1 &
  echo "넥슨 플러그를 켰어요."
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
  printf '%-14s %s\n' "Wine" "$([ -x "$WINE_DIR/bin/wine" ] && "$WINE_DIR/bin/wine" --version || echo 없음)"
  printf '%-14s %s\n' "DXMT" "$([ -f "$WINE_DIR/lib/wine/x86_64-unix/winemetal.so" ] && [ -f "$WINE_DIR/lib/wine/x86_64-windows/d3d11.dll.wined3d" ] && echo 설치됨 || echo 없음)"
  printf '%-14s %s\n' "Wine 환경" "$([ -d "$DRIVE_C" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "WebView2" "$([ -d "$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView/Application" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "넥슨 플러그" "$([ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "NGM" "$([ -f "$DRIVE_C/ProgramData/Nexon/NGM/NGM64.exe" ] && echo 있음 || echo 없음)"
  printf '%-14s %s\n' "게임" "$([ -f "$DRIVE_C/Nexon/AzurPromilia/AzurPromilia.exe" ] && echo 있음 || echo 없음)"
}

cmd_status_code() { # 앱이 쓰는 한 단어 상태: ready | setup
  if [ -x "$WINE_DIR/bin/wine" ] && [ -f "$WINE_DIR/lib/wine/x86_64-windows/d3d11.dll.wined3d" ] \
     && [ -f "$DRIVE_C/Nexon/NexonPlug/NexonPlug.exe" ] && [ -f "$DRIVE_C/ProgramData/Nexon/NGM/NGM64.exe" ]; then
    echo ready
  else
    echo setup
  fi
}

# 이 맥에 이미 있는 재료를 찾아서 setup 옵션으로 출력해요 (다운로드를 줄이려고).
#  - Yaagl이 받아 둔 같은 Wine 빌드와 같은 DXMT 빌드
#  - CrossOver "Azur Promilia" 보틀의 WebView2 런타임과 이미 받은 게임
DXMT_D3D11_SHA256="fbb95116abaf69a55495fcffc8956bcfbe2b815f3862e44a01d18329bf668739"
cmd_detect_sources() {
  local d wine_src="" dxmt_src="" out=""
  for d in "$HOME/Library/Application Support/"Yaagl*; do
    [ -d "$d" ] || continue
    if [ -z "$wine_src" ] && [ -x "$d/wine/bin/wine" ] \
       && grep -q '11.0-1-crossover-signed-experimental' "$d/.storage/wine_tag.neustorage" 2>/dev/null; then
      wine_src="$d/wine"
    fi
    if [ -z "$dxmt_src" ] && [ -f "$d/dxmt/d3d11.dll" ] && [ -f "$d/dxmt/winemetal.so" ] \
       && [ "$(shasum -a 256 "$d/dxmt/d3d11.dll" | awk '{print $1}')" = "$DXMT_D3D11_SHA256" ]; then
      dxmt_src="$d/dxmt"
    fi
  done
  local b="$HOME/Library/Application Support/CrossOver/Bottles/Azur Promilia/drive_c"
  [ -n "$wine_src" ] && out+="--wine-from $(printf '%q' "$wine_src") "
  [ -n "$dxmt_src" ] && out+="--dxmt-from $(printf '%q' "$dxmt_src") "
  if [ -d "$b/Program Files (x86)/Microsoft/EdgeWebView/Application" ]; then
    out+="--webview2-from $(printf '%q' "$b/Program Files (x86)/Microsoft/EdgeWebView") "
  fi
  if [ -f "$b/Nexon/AzurPromilia/AzurPromilia.exe" ]; then
    out+="--import-crossover $(printf '%q' "Azur Promilia") "
  fi
  echo "$out"
}

cmd_setup() { # [--wine-from DIR] [--dxmt-from DIR] [--webview2-from DIR] [--import-crossover BOTTLE]
  local wine_from="" dxmt_from="" wv2_from="" import_bottle=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wine-from) wine_from="$2"; shift 2 ;;
      --dxmt-from) dxmt_from="$2"; shift 2 ;;
      --webview2-from) wv2_from="$2"; shift 2 ;;
      --import-crossover) import_bottle="$2"; shift 2 ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
  done
  command -v python3 >/dev/null || die "python3가 필요해요. 터미널에서 xcode-select --install"
  if [ ! -x "$WINE_DIR/bin/wine" ]; then
    say "1/7 Wine 설치"
    if [ -n "$wine_from" ]; then cmd_install_wine --from "$wine_from"; else cmd_install_wine; fi
  fi
  if [ ! -f "$WINE_DIR/lib/wine/x86_64-windows/d3d11.dll.wined3d" ]; then
    say "2/7 DXMT 설치"
    if [ -n "$dxmt_from" ]; then cmd_install_dxmt --from "$dxmt_from"; else cmd_install_dxmt; fi
  fi
  say "3/7 Wine 환경 준비"; cmd_init_prefix
  if [ ! -d "$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView/Application" ]; then
    if [ -n "$wv2_from" ]; then say "4/7 WebView2 런타임"; cmd_install_webview2 --from "$wv2_from"
    else warn "WebView2 런타임이 없어요. NGM(설치 화면)에 필요해요. README의 'WebView2' 항목을 참고하세요."; fi
  fi
  say "5/7 넥슨 플러그 설치"; cmd_install_plug
  say "6/7 NGM 설치"; cmd_install_ngm
  say "7/7 호환 설정"; cmd_configure
  if [ -n "$import_bottle" ] && [ ! -e "$DRIVE_C/Nexon/AzurPromilia" ]; then
    say "CrossOver에 받아 둔 게임 가져오기"; cmd_import_crossover "$import_bottle"
  fi
  wserver -w 2>/dev/null || true
  say "준비 완료. ./azurctl.sh plug 로 넥슨 플러그를 켜세요."
}

sub="${1:-status}"; shift || true
case "$sub" in
  setup|install-wine|install-dxmt|init-prefix|install-webview2|install-plug|install-ngm|configure|link-game|import-crossover|plug|game-direct|stop|status|status-code|detect-sources|winecfg|shell)
    "cmd_${sub//-/_}" "$@" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
