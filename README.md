# 아주르 프로밀리아 런처 (무료 Wine + DXMT, 실험 단계)

CrossOver 없이 무료 Wine과 DXMT로 넥슨 플러그와 아주르 프로밀리아(한국 PC판)를 Apple Silicon 맥에서 돌리는 비공식 런처예요. Wine은 CodeWeavers가 공개한 CrossOver 소스로 이 저장소에서 직접 빌드해서 배포해요.

> **비공식 실험 프로젝트예요.** 넥슨, 만쥬, CodeWeavers와 관련이 없어요.
> 넥슨은 macOS와 Wine을 지원하지 않아요. 계정 제재 등의 위험은 본인 책임이에요.
> 넥슨 파일은 이 저장소에 없어요. 실행할 때 넥슨 공식 서버(`platform.nexon.com`)에서 받아요.

## 지금 상태 (2026-11-26 기준)

| 항목 | 결과 |
|---|---|
| 직접 빌드한 Wine + DXMT 런타임 자동 다운로드 (체크섬 확인) | 됨 |
| 넥슨 플러그 화면 표시, 로그인 | 됨 |
| CrossOver에 받아 둔 게임을 "설치 완료"로 인식 | 됨 (다시 받지 않고 연결) |
| 게임 실행 파일: DXMT 그래픽, 넥슨 보안(NGS-X) 초기화 | 됨 (자체 빌드 런타임에서 3번 중 3번) |
| WebView2 자동 설치 (Microsoft 공식 설치 프로그램, 109 버전) | 됨 |
| CrossOver 없이 넥슨 플러그에서 게임 설치 시작 | 됨 (NGM이 WebView2를 띄우고 다운로드 시작까지 확인) |
| 넥슨 플러그에서 게임 실행 | 됨 (오픈 당일 시작 화면 약 55fps, Metal HUD 기준) |
| 게임 안 한글 표시 | 됨 (런처가 한글 글꼴을 넣어 줘요) |
| 한글·영문 키보드 입력 | 됨 (자체 빌드 런타임) |

게임 실행 파일은 런처를 거치지 않고 직접 켜서 확인했어요. 로그인 정보가 없어서 로그인 SDK 단계(오류 10121)에서 꺼지는 게 정상이에요. CrossOver에서도 같은 단계까지 가요.

**테스트 환경:** MacBook Pro (M5 Pro, 24GB), macOS 27.0.1, Wine (CrossOver 26.3 공개 소스로 직접 빌드), DXMT v0.80

## 쓰는 법

### 앱 받아서 쓰기 (쉬운 방법)

1. [Releases](https://github.com/SELCORE/azur-promilia-launcher/releases)에서 `Azur-Promilia-Launcher.zip`을 받아 압축을 풀어요.
2. `Azur Promilia Launcher.app`을 응용 프로그램 폴더로 옮겨요.
3. 앱을 열어요. 처음에는 Apple 인증이 없는 앱이라 열리지 않아요.
   - **시스템 설정 > 개인정보 보호 및 보안**에서 맨 아래 **그래도 열기**를 누르세요.
   - 한 번만 하면 돼요.

### 직접 빌드하기

```bash
git clone https://github.com/SELCORE/azur-promilia-launcher.git
cd azur-promilia-launcher
./build-app.sh            # dist/Azur Promilia Launcher.app 이 만들어져요 (Xcode 명령줄 도구 필요)
open "dist/Azur Promilia Launcher.app"
```

### 처음 실행하면

확인 창이 뜨고 준비를 시작해요. 인터넷 속도에 따라 몇 분 걸려요.

1. 이 저장소의 릴리스에서 Wine + DXMT 런타임(약 281MB)을 받아요.
   - 받은 파일은 체크섬으로 확인해요.
2. NGM에 필요한 WebView2 런타임을 Microsoft 공식 설치 프로그램으로 설치해요 (약 150MB).
   - 최신 버전은 Wine에서 잘 돌지 않아서, 설치하는 동안만 윈도우 버전을 Windows 7로 알려서 109 버전을 받아요.
   - 이 버전으로 고정되게 자동 업데이트를 꺼요.
3. 넥슨 공식 서버에서 넥슨 플러그와 NGM을 받아요.
4. 검은 화면 방지와 창 설정을 적용해요.
5. CrossOver의 `Azur Promilia` 보틀이 있으면 WebView2를 받지 않고 거기서 복사하고, 받아 둔 게임도 다시 받지 않고 연결해요.

**두 번째부터는** 앱을 열면 넥슨 플러그가 바로 켜져요.

모든 파일은 `~/Library/Application Support/Azur Promilia Launcher/`에 저장돼요.

| 폴더 | 내용 |
|---|---|
| `wine/` | Wine 본체 (DXMT 포함) |
| `prefix/` | 윈도우 환경 (C 드라이브) |
| `logs/` | 준비·실행 기록 |

## 설정

런처 창에서 바꿀 수 있어요. 다음에 넥슨 플러그를 켤 때 적용돼요 (넥슨 플러그가 게임을 켜면서 그대로 이어져요).

| 설정 | 하는 일 |
|---|---|
| Metal HUD | 게임 화면 위에 FPS와 GPU 정보를 표시해요 |
| Retina 모드 | 맥 화면의 원래 해상도로 그려요. 선명하지만 훨씬 무거워져요 |
| 왼쪽 CMD를 CTRL로 할당 | 왼쪽 ⌘ 키를 Ctrl 키로 써요 |
| 사용자 정의 해상도 | 넥슨 플러그를 켤 때마다 게임 해상도를 이 값으로 맞춰요 (게임 안 설정보다 우선) |
| 사용자 지정 모니터 주사율 | 게임 주사율과 DXMT 프레임 상한을 이 값으로 맞춰요. FPS가 60 아래로 묶일 때 켜세요 |

터미널에서는 `./azurctl.sh settings`로 보고, `./azurctl.sh set metal_hud 1`처럼 바꿔요.

**넣지 않은 설정:** 다른 런처에 있는 아래 설정은 이 게임에 맞지 않거나 하지 않기로 해서 넣지 않았어요.
- **안티치트(AC) 패치, hosts 수정:** 넥슨 보안 모듈을 건드리거나 넥슨 서버 접속을 막는 일이라 계정 제재 위험이 커요. 이 런처는 보안 모듈을 수정하지 않아요.
- **Steam 패치, Workaround #3:** 다른 회사 게임 전용이거나 이미 아무 일도 하지 않는 설정이에요.
- **HDR:** 이 게임 빌드는 HDR이 꺼진 채로 나와서, 게임 파일을 고치지 않고는 켤 수 없어요.
- **타임아웃 문제 해결:** 다른 런처의 Wine에 따로 넣은 수정이라, CrossOver 소스를 그대로 빌드한 이 런타임에는 없어요.

## 터미널 명령어

| 명령어 | 하는 일 |
|---|---|
| `./azurctl.sh setup` | 모두 준비해요. 옵션: `--runtime-from <tar.xz>`, `--webview2-from <폴더>`, `--import-crossover <보틀>` |
| `./azurctl.sh detect-sources` | CrossOver 보틀에서 재사용할 수 있는 WebView2와 게임을 찾아 setup 옵션으로 출력해요 |
| `./azurctl.sh plug` | 넥슨 플러그를 켜요 |
| `./azurctl.sh stop` | 이 런처의 Wine 프로세스를 모두 종료해요 |
| `./azurctl.sh status` | 설치 상태를 보여줘요 |
| `./azurctl.sh import-crossover [보틀]` | CrossOver 보틀에 받아 둔 게임을 연결해요 (복사 없음) |
| `./azurctl.sh game-direct` | 넥슨 플러그 없이 게임 실행 파일만 켜 봐요 (그래픽·보안 모듈 확인용) |

## 알려진 문제

- **게임 안 글자가 깨지던 문제 (해결)**
  - 게임 일부 화면이 윈도우 글꼴(MiSans, Noto Sans S Chinese, 맑은 고딕)을 찾는데 Wine에는 없어서 한글이 빠져 보였어요.
  - 런처가 맥에 있는 한글 글꼴(AppleGothic)을 그 이름으로 복사해 Wine 글꼴 폴더에 넣어요. 이 맥 안에서만 쓰는 복사본이에요.
- **"게임 실행에 실패했습니다"가 뜨는데 게임은 켜지던 문제 (해결)**
  - NGM이 Wine에서 켜지지 않는 "Nexon Launcher" 서비스를 기다리느라 늦어져서 넥슨 플러그가 실패로 판단했어요.
  - 런처가 넥슨 플러그를 켤 때 이 서비스를 꺼 둬서, NGM이 바로 게임을 켜요.

- **DXMT 초기화 중 튕김 (예전 버전)**
  - 예전 런타임(DXMT 654f547)에서는 게임을 켜자마자 `NSInvalidArgumentException` 오류로 가끔 꺼졌어요.
  - 지금 런타임(DXMT v0.80)에서는 3번 시험해서 한 번도 나지 않았어요. 다시 나면 알려 주세요.
- **키보드 입력 (예전 버전)**
  - 예전 런타임에서는 맥 한글 입력기가 제대로 동작하지 않았어요.
  - 지금 런타임(CrossOver 26.3 소스 빌드)에서는 넥슨 플러그에서 한글과 영문 입력이 모두 잘 돼요.
- **CrossOver에서 가져온 게임**
  - 복사가 아니라 연결이에요. CrossOver 보틀을 지우면 게임도 같이 사라져요.
- **넥슨 플러그 창 표시**
  - 소프트웨어 렌더링 옵션(`--use-gl=swiftshader --use-angle=swiftshader --in-process-gpu`)으로 켜요. 그래야 화면이 나와요.

## 런타임 직접 빌드하기

GitHub Actions의 **build-runtime** 워크플로를 실행하면 Wine + DXMT 런타임이 만들어져요. 맥에서 직접 빌드하려면 이렇게 하세요.

```bash
runtime/build-runtime.sh all    # 결과: runtime-work/out/azur-runtime-*.tar.xz
./azurctl.sh setup --runtime-from runtime-work/out/azur-runtime-*.tar.xz
```

## 제거

1. `./azurctl.sh stop`을 실행해요.
2. `~/Library/Application Support/Azur Promilia Launcher` 폴더와 앱을 지워요.

## 출처와 라이선스

- **Wine:** CodeWeavers가 공개한 [CrossOver 26.3 소스](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz)를 고치지 않고 [`runtime/build-runtime.sh`](runtime/build-runtime.sh)로 빌드해요 (LGPL).
- **DXMT:** [3Shain/dxmt v0.80](https://github.com/3Shain/dxmt/releases/tag/v0.80) 공식 릴리스를 넣어요 (CodeWeavers의 Feifan He 제작, LGPL).
- **라이브러리:** GMP, Nettle, GnuTLS, FreeType을 각 공식 소스 릴리스에서 같은 스크립트로 빌드해 넣어요. 정확한 출처는 런타임 안의 `SOURCES.txt`에 있어요.
- **이 저장소:** 스크립트는 MIT 라이선스예요. 넥슨, 넥슨 플러그, 아주르 프로밀리아는 각 권리자의 상표이자 저작물이에요.
