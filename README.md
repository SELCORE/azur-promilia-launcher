# 아주르 프로밀리아 런처 (무료 Wine + DXMT, 실험 단계)

CrossOver 없이 무료 Wine과 DXMT로 넥슨 플러그와 아주르 프로밀리아(한국 PC판)를 Apple Silicon 맥에서 돌리는 비공식 런처예요. Yaagl과 같은 방식이에요.

> **비공식 실험 프로젝트예요.** 넥슨, 만쥬, CodeWeavers, Yaagl과 관련이 없어요.
> 넥슨은 macOS와 Wine을 지원하지 않아요. 계정 제재 등의 위험은 본인 책임이에요.
> 넥슨 파일은 이 저장소에 없어요. 실행할 때 넥슨 공식 서버(`platform.nexon.com`)에서 받아요.

## 지금 상태 (2026-11-26 새벽 기준)

| 항목 | 결과 |
|---|---|
| Wine·DXMT 자동 다운로드 (GitHub, 체크섬 확인) | 됨 |
| 넥슨 플러그 화면 표시, 로그인 | 됨 |
| CrossOver에 받아 둔 게임을 "설치 완료"로 인식 | 됨 (다시 받지 않고 연결) |
| 게임 실행 파일: DXMT 그래픽, 넥슨 보안(NGS-X) 초기화 | 됨: 7번 중 5번. 나머지 2번은 DXMT 초기화 중 튕김 (아래 알려진 문제) |
| WebView2 자동 설치 (Microsoft 공식 설치 프로그램, 109 버전) | 됨 |
| CrossOver 없이 넥슨 플러그에서 게임 설치 시작 | 됨 (NGM이 WebView2를 띄우고 다운로드 시작까지 확인) |
| 넥슨 플러그에서 게임 실행, 실제 플레이 | **확인 전** (11월 26일 11시 오픈 뒤 확인) |
| 키보드 입력 | **문제 있음** (아래 알려진 문제) |

게임 실행 파일은 런처를 거치지 않고 직접 켜서 확인했어요. 로그인 정보가 없어서 로그인 SDK 단계(오류 10121)에서 꺼지는 게 정상이에요. CrossOver에서도 같은 단계까지 가요.

**테스트 환경:** MacBook Pro (M5 Pro, 24GB), macOS 27.0.1, Wine 11.0 (CrossOver 공개 소스 빌드), DXMT 654f547

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
./build-app.sh            # dist/Azur Promilia Launcher.app 이 만들어져요
open "dist/Azur Promilia Launcher.app"
```

### 처음 실행하면

확인 창이 뜨고 준비를 시작해요. 인터넷 속도에 따라 몇 분 걸려요.

1. 무료 Wine(약 435MB)과 DXMT(약 31MB)를 GitHub에서 자동으로 받아요.
   - 받은 파일은 체크섬으로 테스트한 빌드와 같은지 확인해요.
   - 이 맥에 Yaagl이 받아 둔 같은 버전이 있으면 받지 않고 그걸 복사해서 써요.
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

## 터미널 명령어

| 명령어 | 하는 일 |
|---|---|
| `./azurctl.sh setup` | 모두 준비해요. 옵션: `--wine-from`, `--dxmt-from`, `--webview2-from`, `--import-crossover <보틀>` |
| `./azurctl.sh detect-sources` | 이 맥에서 재사용할 수 있는 Wine, DXMT, WebView2, 게임을 찾아 setup 옵션으로 출력해요 |
| `./azurctl.sh plug` | 넥슨 플러그를 켜요 |
| `./azurctl.sh stop` | 이 런처의 Wine 프로세스를 모두 종료해요 |
| `./azurctl.sh status` | 설치 상태를 보여줘요 |
| `./azurctl.sh import-crossover [보틀]` | CrossOver 보틀에 받아 둔 게임을 연결해요 (복사 없음) |
| `./azurctl.sh game-direct` | 넥슨 플러그 없이 게임 실행 파일만 켜 봐요 (그래픽·보안 모듈 확인용) |

## 알려진 문제

- **DXMT 초기화 중 가끔 튕김**
  - 게임을 켜자마자 `NSInvalidArgumentException ... newComputePipelineStateWithDescriptor` 오류로 꺼질 때가 있어요.
  - 다시 켜면 대부분 넘어가요. 원인은 아직 몰라요.
- **키보드 입력 (한글 입력기)**
  - 무료 Wine은 맥의 한글 입력기를 제대로 처리하지 못해요. CrossOver에는 이 문제를 고치는 자체 수정이 있어요.
  - 맥 입력 소스가 한글인 상태로 넥슨 플러그를 켜면, 영문으로 바꿔 쳐도 한글이 들어가거나 아무것도 입력되지 않을 수 있어요.
  - **로그인:** 넥슨 앱으로 하는 **일회용 로그인** 탭을 쓰면 키보드 입력 없이 로그인할 수 있어요. 넥슨 플러그를 켜기 전에 입력 소스를 영문(ABC)으로 바꿔 두는 방법도 있는데, 아직 확인하지 못했어요.
  - **게임 안 한글 입력**(닉네임, 채팅)은 아직 안 될 가능성이 높아요.
- **CrossOver에서 가져온 게임**
  - 복사가 아니라 연결이에요. CrossOver 보틀을 지우면 게임도 같이 사라져요.
- **넥슨 플러그 창 표시**
  - 소프트웨어 렌더링 옵션(`--use-gl=swiftshader --use-angle=swiftshader --in-process-gpu`)으로 켜요. 그래야 화면이 나와요.

## 제거

1. `./azurctl.sh stop`을 실행해요.
2. `~/Library/Application Support/Azur Promilia Launcher` 폴더와 앱을 지워요.

## 출처와 라이선스

- **Wine:** CodeWeavers가 공개한 소스로 만든 빌드를 [Yaagl 프로젝트의 릴리스](https://github.com/yaagl/anime-game-wine/releases)에서 받아요. Wine은 LGPL 라이선스예요.
- **DXMT:** [3Shain/dxmt](https://github.com/3Shain/dxmt) 빌드를 같은 릴리스에서 받아요.
- **설치 방식:** DXMT를 Wine에 넣는 방식은 [Yaagl](https://github.com/yaagl/yet-another-anime-game-launcher)(MIT)을 참고했어요.
- **이 저장소:** 스크립트는 MIT 라이선스예요. 넥슨, 넥슨 플러그, 아주르 프로밀리아는 각 권리자의 상표이자 저작물이에요.
