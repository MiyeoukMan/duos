# DuoS — 아이폰 듀오용 닌텐도 DS 에뮬레이터

아이폰 듀오를 **반쯤 접어 세로로 들면** 진짜 DS처럼: 접힌 선 위가 위 화면, 아래 판이 터치 화면과 버튼.
에뮬레이션 코어는 [melonDS](https://melonds.kuribo64.net) 1.1(GPL-3.0)을 그대로 쓰고, 이 저장소는 그 위의 iOS 앱 · 감싸개 · 시험 도구다.

## 접기 · 펼치기 = DS 닫기 · 열기

전체가 DS Lite처럼 생겼다(본체 색 6가지 — 설정 › 본체 색). 닌텐도 로고 · 상표는 그리지 않았다.
펼친 화면은 기본이 **실기기 비율**(DS Lite 실측 mm — 본체 폭 133 · 화면 62 × 46.5 · 십자키/ABXY · START/SELECT 자리 — 를 듀오 폭에 맞춰 줄임), 설정 › 펼친 화면 배치에서 **화면 크게**도 고를 수 있다.

| 상태 | 화면 |
|---|---|
| 접음(바깥 화면) | DS 뒷면(가로 한 방향 고정 — 카드 슬롯이 경첩 쪽). 위 가장자리는 얇은 띠에 카드 슬롯만(경첩 · L/R · 불빛 없음), 판에 스티커(꽂힌 게임 · 안내가 천천히 깜빡임) · 배터리 덮개. 슬롯이 경첩 반대쪽이면 설정 › 접은 화면 뒤집기 |
| 슬롯 누름 | 카트리지 고르기(ROM 배너의 아이콘 · 제목으로 라벨을 만든 카드가 옆으로 늘어섬) → 고르면 슬롯 앞으로 와서 뒤집히고(금색 단자) 슬롯 속으로 "딸깍". 꽂는 순간 뒤에서 ROM을 읽어 부팅해 둔다. 꽂힌 카드를 누르면 빠진다 |
| 배터리 덮개 누름 | 덮개가 아래로 밀려 열리며(배터리 칸이 보임) 설정 창, 닫으면 딸깍 닫힘 |
| 펼침 | 펼친 DS(늘 세로). 카드가 있으면 바로 게임이 돈다, 없으면 "카드 없음" 화면(시계 · 안내). SETTINGS 버튼 = 설정(게임 메뉴 포함) |
| 다른 방향으로 들고 있을 때 | 그래도 접음 = 가로, 펼침 = 세로(앱이 시스템 방향을 돌려 잠근다). 바뀌는 순간은 화면이 잠깐 검었다가 나타난다 |
| 접는 순간 | 그 자리를 자동 저장(`States/<이름>.suspend.mst`) + 세이브 쓰기, 멈춤. 전원 불빛이 천천히 깜빡인다. 다시 펼치면(앱을 껐다 켜도) 이어서 |

- 화면 방향: 접음 = 가로, 펼침 = 세로로 **고정**(기기를 돌려도 안 돈다). 듀오(iOS 27)는 앱이 창 모드로 돌아 방향 요청을 거절하는데(UISceneErrorDomain 101), **Info.plist의 `UIRequiresFullScreen`이 있으면 받아 준다** → 접고 펼 때 `requestGeometryUpdate`로 돌리고 `prefersInterfaceOrientationLocked`로 잠근다. 지원 방향을 하나로 좁히면 돌리지 않고 작은 세로 창(양옆 검은 띠)으로 띄우므로 좁히지 않는다. 시스템의 회전 애니메이션은 끌 수 없어서 도는 동안 화면을 검게 감췄다가 나타나게 한다. 시스템이 끝내 안 돌려 주면(0.7초) 예비로 그림 판(`stage`)을 90° 돌려 그린다.
- 게임 모드: `LSApplicationCategoryType = games` + `GCSupportsGameMode` — 화면 방향과는 상관없고, 컨트롤러 지연 · 백그라운드 작업을 줄여 준다.
- 접힘은 iOS 27.1의 `UIHingeInteraction`(상태 · 각도)으로 읽는다. 이 API는 접힌 선의 자리를 알려 주지 않으므로 화면 한가운데로 본다.
- 설정의 게임 메뉴: 빠른 저장/불러오기(`States/<이름>.mst`) · 빨리 감기 · 위아래 화면 바꾸기 · 처음부터 다시(이어 할 자리 지움) · 카트리지 빼기.

## 근거리 무선(DuoDS끼리 · 맥의 melonDS와)

설정 › **무선 통신**. melonDS의 LAN 기능(DS 근거리 무선을 Wi-Fi의 UDP로 — ENet, 포트 7064)을 그대로 쓴다.

- **방 만들기**(방장) / **주변 방**(같은 Wi-Fi의 DuoDS — Bonjour `_duods._udp`) / **IP로 참가**(맥 melonDS가 연 방 등). 참가자 목록 · 핑이 보이고, 연결 중엔 경첩에 주황 무선 불빛.
- 모두 **같은 게임을 꽂고** 게임 안의 통신 메뉴(대전 · 협력)로 들어간다. **다운로드 플레이는 안 된다**(DS 본체 메뉴가 필요 — FreeBIOS로는 부팅 불가).
- 아이폰은 특별 권한(멀티캐스트 엔타이틀먼트) 없이 UDP 방송을 못 써서, melonDS의 방송 찾기(7063) 대신 Bonjour로 찾는다. 그래서 맥 melonDS ↔ DuoDS는 서로 목록에 안 보이고 **IP로 직접** 붙는다(DuoDS 화면에 "이 기기 IP"가 나온다). melonDS는 같은 버전이어야 한다.
- 처음 쓸 때 iOS가 **로컬 네트워크 접근**을 묻는다 — 허용해야 한다.
- 기기마다 DS 무선 주소(MAC)가 달라야 해서 처음 켤 때 무작위로 만들어 둔다(00:09:BF:xx:xx:xx).
- 시험: `build/macos/lantest host 이름 [초] [최대]` · `lantest join 이름 IP [초]` — 게임 없이 방 · 참가 · 목록만. 시뮬레이터는 mDNS 데몬에 못 닿아(ServiceNotRunning) Bonjour 찾기는 실제 기기에서만 된다.
- 무언가를 띄우면(시트 · 알림) 시스템이 화면 방향 잠금을 풀어 버린다 → 설정은 게임 화면 위에 얹는 카드, 무선 화면엔 알림창을 쓰지 않는다.

## 인터넷(Nintendo WFC 대체 서버 — Wiimmfi · Kaeru WFC)

설정 › **인터넷(WFC)**. 닌텐도 WFC는 2014년에 닫혔으니 게임의 온라인 메뉴는 사설 서버로 보낸다.

- 길: 게임 → melonDS 가상 공유기(WifiAP, 펌웨어에 `melonAP`로 잡혀 있음) → libslirp(사용자 공간 NAT — DHCP · ARP도 답한다) → 이 기기의 보통 소켓. 아이폰에서 따로 받을 권한이 없다(`core/DuoNet.cpp`).
- **DNS만 가로챈다**: 게임의 UDP 53 질의는 어느 주소로 가든 고른 서버의 DNS로 넘기고, 답은 게임이 물은 주소에서 온 것처럼 돌려준다 → 게임 안 DNS 설정과 상관없이 `nintendowifi.net`이 사설 서버를 가리킨다.
- 프리셋(2026-10-25에 각 DNS에 `nas.nintendowifi.net`을 물어 확인): Wiimmfi `95.217.77.151`(기본) · Kaeru WFC `178.62.43.212` · 직접 입력(IPv4 — 틀리면 꺼진 채). 화면의 "연결 시험"은 서버 DNS에 바로 묻는다.
- **Nintendo WFC 설정(접속 ID)**: 게임이 처음 접속할 때 펌웨어의 접속점 칸에 쓰는 것. 펌웨어는 켤 때마다 새로 만들므로 이 칸(확장 3 + 보통 3 = 2304바이트)만 `Application Support/wfcsettings.bin`에 남겨 되살린다(melonDS의 wfcsettings.bin과 같은 방식). 화면에서 지울 수 있다(카트리지를 뺐을 때만).
- 게임이 주고받는 동안 경첩의 무선 불빛이 켜진다. 서버가 지원하는 게임만 되고, 대전 같은 직접 연결은 공유기(NAT)에 따라 안 될 수 있다.
- **접속 기록**(설정 › 인터넷(WFC) › 접속 기록 · `Documents/Logs/wfc-log.txt`, 512KB 넘으면 `.old`): DHCP · DNS 질의와 답 · TCP 연결/끊김(양) · 암호 없는 내용(GameSpy 로그인 29900 · 친구 검색 29901 · HTTP 80)은 글자 그대로, HTTPS 등은 앞 8바이트 16진수, UDP는 상대마다 3개. 게임을 켤 때 구분 줄. 화면에서 복사 · 지우기. 맥으로 꺼내기:
  `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.singularity2131.duods --source Documents/Logs/wfc-log.txt --destination wfc-log.txt`
- 시험: `build/macos/nettest [서버DNS]` — 게임 없이 이더넷 프레임을 보내 DHCP · DNS 가로채기(가상 DNS · 아무 주소) · TCP(SYN-ACK, `http://conntest.nintendowifi.net/` 받기, GameSpy gpcm:29900의 첫 인사 `\lc\1\`) · UDP(NTP) · 끄기 · WFC 설정 남기기/되살리기/지우기 · 접속 기록 내용을 본다(인터넷 필요). `NETTEST_SHOWLOG=1`이면 기록을 찍는다.

## 화면(그래픽 옵션)

설정 › **화면**. 그리기 단계는 `app/DuoDS/Render/ScreenPipeline.swift`(앱과 맥 비교 도구가 같은 코드): [잔상] → [확대] → 마지막 패스(샘플링 · 색감 · LCD 격자).

- 확대 방식: **MetalFX(권장 · 되는 기기의 기본)** = Scale2x 한 번 뒤 MetalFX 공간 업스케일러로 화면 크기까지(바로 MetalFX를 걸면 도트 외곽선이 구슬처럼 울퉁불퉁해서 앞에 Scale2x) · **도트 다듬기** = Scale2x 두 번(Scale4x) 뒤 선명하게 · 선명하게 · 부드럽게 · 픽셀 그대로. MetalFX는 시뮬레이터 SDK에 없어 `#if canImport(MetalFX)` — 시뮬레이터에선 목록에서 빠지고 선명하게로 그린다.
- 색감(원본 · 생생하게 · 차분하게 — 실기 색을 잰 값은 아님), LCD 격자(약하게 0.12 · 강하게 0.25), 잔상(지난 프레임과 반씩).
- 중간 결과는 새 프레임 · 설정 · 자리 크기가 바뀔 때만 다시 만든다.
- 위의 확대 방식은 다 나온 256×192 그림을 키우는 것이다. 3D 폴리곤 자체를 높은 해상도로 다시 그리는 것은 아래 **3D 해상도**.
- 비교: `swiftc -O tools/gfxshot/main.swift app/DuoDS/Render/ScreenPipeline.swift -o build/macos/gfxshot` → `build/macos/gfxshot 입력.png 출력폴더 1216x912 x,y,w,h`(입력은 256×192 또는 dsrun의 256×384 — 위 화면). 비교판 `build/gfx/compare-2d.png` · `compare-3d.png`.

### 3D 해상도(내부 해상도 1× · 2× · 3× · 4×)

설정 › 화면 › **3D 해상도**(기본 1×). 2배 이상이면 3D만 Metal로 (256×N) × (192×N)에 다시 그린다 — `core/hires/`.

- **1×** = melonDS 소프트웨어 렌더러 그대로(3D는 따로 도는 스레드).
- **2~4×** = `DuoRenderer`: 2D(배경 · 스프라이트 · 합성 · 화면 캡처)는 소프트웨어 렌더러와 같은 코드로 256×192(`DuoRenderer.mm` = GPU_Soft.cpp, `DuoRenderer2D.cpp` = GPU2D_Soft.cpp의 사본 — 바꾼 곳은 `DuoDS:` 표시, melonDS 원본은 그대로). 3D는 `Metal3D.mm`(melonDS OpenGL 3D 렌더러를 Metal로 옮긴 것 — 그리는 순서 · 깊이/스텐실 규칙은 원본 그대로, GL 상태를 흉내 내 그릴 때마다 맞는 파이프라인을 고른다)가 높은 해상도에 그리고, 블록 가운데 텍셀로 1×를 되읽어 2D 합성 · 캡처에 쓴다. 엔진 A는 픽셀마다 "3D가 맨 위인지 · 3D 알파로 밑과 섞는지 · 밝기 · 3D 위의 반투명 층"을 남기고(1×에서 비었어도 창이 허락한 자리는 표시 — 폴리곤 가장자리가 고해상도로 매끈하게), VBlank에 합성 패스(`HiresShaders.mm`의 `compose`)가 그 표시대로 고해상도 3D를 끼운다.
- 앱: 코어가 그 화면의 고해상도 그림(Metal 텍스처, 3장 돌려 씀)을 넘기면 `ScreenPipeline`이 그 그리기 안에서 복사해 **확대 단계(Scale2x · MetalFX)를 건너뛰고** 마지막 패스(샘플링 · 색감 · LCD 격자 · 잔상)로 그린다. 3D가 없는 화면(대개 아래)과 3D가 없는 장면은 원래 확대 방식 그대로. 게임 중에 바꾸면 다음 프레임부터(그 프레임의 3D를 바로 다시 그려 빈 프레임이 없다).
- 원본 GL 렌더러와 달라진 것: 알파 테스트를 넣었다 · 지우기 색 5→6비트를 소프트웨어처럼(×2+1) · **가장자리 표시**가 실제로 된다(GL은 가장자리 깃발이 늘 0) — DS처럼 폴리곤의 기하 가장자리만(무게중심 좌표 + 삼각형마다 "폴리곤 가장자리인 변" 비트, 사각형을 나눈 대각선은 아님), 두께는 DS 1픽셀(= 배율), 화면 밖 이웃은 지우기 면(화면 끝 선). 무게중심 좌표를 못 쓰는 장치(시뮬레이터)는 근사(불투명 픽셀 윤곽 전부 — 투명 텍셀 윤곽에도 선이 생김).
- 한계: 화면 캡처는 1×(3D를 두 화면에 번갈아 그리는 게임의 한쪽 · 모션 블러 같은 효과는 지금 화질) · 3D 텍셀이 비고 1×에선 3D가 있던 가장자리는 3D 밑의 층 하나로 근사(옛 melonDS GL과 같음) · melonDS의 "better polygons" · 와이어프레임(알파 0) 폴리곤 선은 없다(GL과 같음).
- 시험: `dsrun --scale N`(PNG가 N배 — 3D가 없던 화면은 1×를 N배로) · `--scale-at F:N`(도중에 바꾸기) · `python3 tools/mkrom.py --scene3d build/scene3d.nds` = 3D 시험 장면(원근 바둑판 바닥 — 직접 색 텍스처 반복 · 뒤집기, 도는 사각형 — 4색 팔레트 · 0번 투명, 반투명 삼각형 — 2D 바탕과 알파 섞기, 안개 · 가장자리 표시; SELECT 누르는 동안 3D를 아래 화면에, START 누르는 동안 W 버퍼). 비교판: `build/macos/gfxshot --hires build/gfx/compare-3d-scale.png 1216x912 560,560,320,320 1배.png "3D 2×=2배.png" "3D 4×=4배.png"`(앱과 같은 ScreenPipeline으로) → `build/gfx/compare-3d-scale.png`.

## 폴더

```
core/            DSCore.h/.cpp — melonDS NDS를 감싼 C 인터페이스 · Platform_Apple.cpp — 파일/스레드/세이브 · DuoNet.cpp — 인터넷
  hires/         3D 해상도: DuoRenderer(2D 소프트웨어 + 합성) · DuoRenderer2D(GPU2D_Soft 사본) · Metal3D(GL 3D 렌더러 이식) · HiresShaders(MSL)
app/             iOS 앱(Xcode 프로젝트 DuoDS.xcodeproj, 소스는 app/DuoDS 폴더 통째로 동기화)
  DuoDS/Emulation  에뮬레이션 스레드 · 소리(AVAudioEngine) · 화면 넘기기
  DuoDS/Render     ScreenRenderer(MTKView) · ScreenPipeline(잔상 · Scale2x · MetalFX · 색감 · LCD 격자 — 셰이더는 실행 시 컴파일, 빌드 맥에 Metal 툴체인이 없어도 됨)
  DuoDS/Console    ConsoleViewController(접힘 상태 기계) · 펼친 DS(OpenConsoleView · OpenBodyView) · 접은 뒷면(ClosedConsoleView)
                   카트리지(CartridgeView · CartridgePickerView) · GameSession(꽂기 = 부팅, 접기 = 자동 저장) · 본체 색(ConsoleTheme)
  DuoDS/Duo        접힘 감지(HingeMonitor) · 펼친 DS 배치(Layout)
  DuoDS/Game       버튼/터치 판(ControlsView) · 컨트롤러
  DuoDS/Library    ROM 찾기 · 가져오기 · 헤더/아이콘 읽기
  DuoDS/Wireless   근거리 무선(Wireless — 세션 · Bonjour · 펌프) · 무선 통신 화면 · 인터넷(Internet · InternetViewController · NetLogViewController)
tools/           dsrun(화면 없는 실행기) · lantest(무선 연결 시험) · nettest(인터넷 길 시험) · gfxshot(화면 옵션 · 3D 해상도 비교) · mkrom.py(시험 ROM) · test.py · sim-run.sh · device-install.sh
third_party/melonDS   melonDS 원본(git clone, 고치지 않음)
third_party/enet      ENet 1.3.18(MIT) — LAN 통신
(libslirp 4.8 — BSD — 는 melonDS 안 src/net/libslirp를 그대로 빌드)
```

## 빌드 · 시험

```bash
make            # 코어 + build/macos/dsrun
make test       # 직접 만든 시험 ROM으로 27가지 확인(화면 · 버튼 12개 · 터치 · 마이크 · 소리 · 상태 저장 + 3D 해상도 7가지)
tools/sim-run.sh -DuoHinge closed   # iPhone Duo 시뮬레이터에 깔고 접은 상태로 켜기
tools/device-install.sh   # 기기용 빌드 → 기기가 연결되면 설치 · 실행(기기 UDID는 tools/device.local — 저장소에 안 올라감)
TEAM=<유료 팀 ID> tools/release.sh   # App Store용 아카이브 → 업로드(docs/release.md)
```

- 시험 ROM(`tools/testrom/*.c`)은 직접 짠 홈브루: 위 화면 3D 삼각형(십자키 이동 · ABXY 색), 아래 화면 버튼 칸 12개 · 터치 그림판 · 마이크 막대, A를 누르면 440Hz. Xcode clang으로 ARM 목적 파일을 만들고 `mkrom.py`의 작은 링커로 묶는다.
- `dsrun <rom> --frames N --png out.png --press 60-90:A+RIGHT --touch 10-20:100,80 --blow 5-40 --wav out.wav [--scale 4]`
- 시뮬레이터엔 접힘이 없다: 실행 인자 `-DuoHinge closed|partial|open`으로 시작 상태를, **두 손가락 톡**으로 접기 ↔ 펴기(시뮬레이터 빌드에만). 기기 방향은 iOS 시뮬레이터 도구로 돌린다.
- 그림만 보기: `-DuoArtPreview open|nocard|carts`, 본체 색은 `-theme polarWhite|jetBlack|iceBlue|crimson|cobalt|coralPink`.
- `python3 tools/mkrom.py --showcase build/showcase` = 아이콘 · 제목이 다른 시험 ROM 4개(카트리지 라벨 확인용, 제목은 지어낸 것).
- 시뮬레이터 녹화 → GIF: `xcrun simctl io <기기> recordVideo a.mp4` 후 `swift tools/video2gif.swift a.mp4 a.gif 560 24 시작초 끝초`.
- 서명: 무료 팀 3C3P339A53, 번들 ID `com.singularity2131.duods`. 무료 팀 앱은 7일 뒤 다시 깔아야 한다.

## 라이선스

melonDS가 GPL-3.0이므로 이 앱도 GPL-3.0을 따른다. 상용 게임 ROM · 닌텐도 바이오스는 들어 있지 않다.
함께 쓰는 라이브러리의 라이선스 전문은 `app/DuoDS/Licenses/`(앱의 설정 › 정보 › 오픈 소스 라이선스). 출시 준비 · 남은 일은 `docs/release.md`, 개인정보처리방침 초안은 `docs/privacy-policy.md`.

앱 이름은 **DuoS**(2026-10-26 DuoDS에서 바꿈 — 번들 ID `com.singularity2131.duods` · Xcode 타깃 `DuoDS`는 그대로). 처음 켜면 데모 카트리지(`app/DuoDS/Samples/duos-demo.nds`, `python3 tools/mkrom.py --demo`)를 ROMs에 한 번 넣는다.
