# DuoS 출시 준비(App Store)

2026-10-26 기준. 법률 자문이 아니라 심사 지침과 앱 상태를 맞춰 본 정리다.

## 앱 정보

| 항목 | 값 |
|---|---|
| 이름(홈 화면 · 스토어) | **DuoS** (`CFBundleDisplayName` · `CFBundleName`) |
| 번들 ID | `com.singularity2131.duods` — 그대로(바꾸면 기기에 깔린 앱 · 세이브와 별개의 새 앱이 된다) |
| Xcode 타깃 · 실행 파일 이름 | `DuoDS`(안 보이는 이름 — 스크립트가 쓴다) |
| 버전 | **1.0** · 빌드 번호는 올릴 때 `tools/release.sh`가 날짜 · 시각으로(yymmddHHMM) |
| 대상 기기 | **폴더블 아이폰 전용**(아이폰 듀오 포함 — 2026-10-26 사용자 결정). 아이폰 에어 등 일반 기기용 빌드 · 설치는 하지 않는다 |
| 스토어 설정 | 아이폰 전용(`TARGETED_DEVICE_FAMILY = 1`) |
| 최소 iOS | 26 |

## 폴더블 전용이라는 것

- App Store에는 "접히는 기기에만 설치"를 거는 방법이 없다. `UIRequiredDeviceCapabilities` 키 34개 중 접힘 · 경첩 관련 키가 없다(Apple "Required Device Capabilities" 페이지, 2026-10-26 확인). 그래서 일반 아이폰(과 아이패드 호환 모드)에도 깔릴 수 있고, **심사도 일반 아이폰에서 할 수 있다** → 접히지 않는 기기에선 펼친 화면 + "여기서 카트리지 고르기"로 돌게 둔다(이미 그렇게 돼 있다).
- 접히는 기기 알아보기: 아이폰 듀오(모델 `iPhone19,4`)이거나, 한 번이라도 경첩 정보(`UIHingeInteraction`)를 받은 기기 — 받으면 기억한다(`hingeSeen`). 그래서 듀오 다음의 폴더블 아이폰도 따로 고치지 않고 알아본다. 아이폰 17 시뮬레이터는 경첩 정보를 보내지 않음을 확인.
- 스토어 설명 · 스크린샷은 폴더블 기준으로. 보도(36kr)에 따르면 2027년 4월부터 새 앱 · 업데이트에 아이폰 듀오용 스크린샷이 필요해진다 — Apple 공지로 직접 확인할 것.

## 이번에 해 둔 것

- [x] 이름 DuoDS → DuoS(화면에 보이는 곳 모두 — 스티커 · 카드 그림 · 설정 · 권한 안내 · 파일 종류 이름 "NDS ROM")
- [x] 접은 뒷면 "▲ GAME CARD" → "▲ CARTRIDGE"
- [x] "Nintendo WFC" 표기 → "온라인 플레이" · "Wi-Fi 접속 설정" · "온라인 접속 정보"(서버 이름 "Kaeru WFC"는 그쪽 이름이라 그대로)
- [x] 개인정보 매니페스트 `app/DuoDS/PrivacyInfo.xcprivacy`: 추적 없음 · 수집 데이터 없음 · 이유를 밝혀야 하는 API 3가지(UserDefaults `CA92.1`, `mach_absolute_time` `35F9.1`, 파일 정보 `stat` `C617.1`)
- [x] 수출 규정 `ITSAppUsesNonExemptEncryption = NO`(앱이 직접 암호화를 쓰지 않는다 — App Store Connect 질문에서 다시 확인)
- [x] 설정 › 정보 › 오픈 소스 라이선스: melonDS(GPL-3.0) · teakra · ENet · libslirp · blip_buf(LGPL-2.1) · FatFs · xxHash · tiny-AES-c · SHA-1 — 전문은 `app/DuoDS/Licenses/`(원본 폴더의 라이선스 파일을 그대로 옮김)
- [x] 데모 카트리지 `app/DuoDS/Samples/duos-demo.nds`(직접 만든 시험 프로그램 — 버튼 · 터치 그림판 · 마이크 · 3D · 소리, `python3 tools/mkrom.py --demo`). 처음 켤 때 ROMs에 한 번 넣는다(지우면 다시 안 넣음)
- [x] 접히지 않는 기기: 카드가 없을 때 안내가 "아래 버튼을 눌러 카트리지를 고르세요", 좁은 아이폰에서 SETTINGS 글씨가 잘리던 것 고침, 작은 아이폰을 접힌 듀오로 잘못 보는 경우 막음(`HingeMonitor.isDuo`)
- [x] 확인(접히지 않는 기기에서도 심사가 통과하게): 아이폰 17 · 아이패드 Air 13 시뮬레이터에서 새로 깔기 → 데모 카트리지 → 실행

## 저장소 · 업로드 · 스크린샷(2026-10-26 해 둠)

- **git 저장소**: `git init`(main) · `.gitignore`(빌드 산출물 · Xcode 개인 파일 · 게임 파일 · 세이브 — 데모 카트리지만 예외 · `tools/device.local`) · melonDS(7d8dea4) · ENet(2662c0d)는 **서브모듈**(받을 때 `git clone --recursive`). 파일은 모두 스테이징까지 — **첫 커밋은 작성자 이름 · 이메일을 정한 뒤**(공개 저장소에 그대로 남는다). 기기 UDID는 저장소에서 뺐다(`tools/device.local`에만).
- **업로드**: `TEAM=<유료 팀 ID> tools/release.sh` = 코어 시험 → 아카이브(Release · 기기용) → App Store Connect 업로드(`tools/ExportOptions.plist` — method app-store-connect). `EXPORT_ONLY=1`은 .ipa만, `ARCHIVE_ONLY=1`은 아카이브까지. 결과는 `build/release/`.
  - 확인: 무료 팀으로 아카이브까지 성공(DuoS 1.0, 개인정보 매니페스트 들어감). 내보내기는 "No Accounts · App Store 프로파일 없음"으로 실패 — 정상(유료 팀 + Xcode 계정 로그인이 필요).
  - 업로드 전에 **Xcode › 설정 › 계정에 유료 팀의 Apple 계정으로 로그인**해 둔다(스크립트가 그 계정으로 인증서 · 프로파일을 만들고 올린다).
- **스크린샷**: `build/appstore/`(저장소에 안 올라감)
  - `duo/` — 듀오 시뮬레이터 원래 크기: 1 게임 중(펼침, 2007×2853) · 2 접은 뒷면(2853×2007) · 3 카트리지 고르기(2853×2007) · 4 화면 설정(2007×2853)
  - `iphone-6.9/1-play.png` — 6.9형(1320×2868, 아이폰 17 Pro 시뮬레이터에서 찍어 키움) — App Store Connect가 듀오 크기 칸을 안 받을 때 쓸 예비
  - 내용은 모두 직접 만든 데모 · 시험 카트리지(상용 게임 화면 없음). 시뮬레이터엔 MetalFX가 없어 화면 설정에 "선명하게"로 보인다 — 기기에서 다시 찍으면 MetalFX
  - `preview.png` — 한눈에 보기

## 출시 전에 직접 할 것

1. **Apple Developer Program(유료, 연 99달러) 가입.** 지금 서명 팀(3C3P339A53)은 무료 팀이라 App Store에 못 낸다. 가입 후 Xcode의 팀을 바꾸고 App Store Connect에서 번들 ID로 앱을 만든다.
2. ~~**소스 공개(GPL-3.0 의무).**~~ 2026-10-26 끝: 공개 저장소 https://github.com/MiyeoukMan/duos (작성자 KELP STUDIO), 앱 설정 › 정보 › "소스 코드"가 그 주소를 연다. 받기: `git clone --recursive https://github.com/MiyeoukMan/duos.git`. 앞으로 앱을 고치면 커밋해서 올려 두기(출시한 빌드의 소스와 맞게).
3. **melonDS 팀에 문의(권장).** App Store 약관과 GPL이 맞지 않는다는 논란이 있다(2011년 VLC가 이 문제로 내려감). melonDS 저작권자에게 App Store 배포에 대한 입장을 미리 물어 두는 게 안전하다.
4. **개인정보처리방침 게시.** `docs/privacy-policy.md`(한/영 초안 — 시행일 · 연락처 빈칸)를 웹에 올리고 주소를 App Store Connect에 넣는다.
5. **App Store 개인정보 항목.** 개발자 서버가 없으니 "데이터를 수집하지 않음"이 기본 답. 다만 온라인 플레이를 켜면 게임이 사용자가 고른 외부 서버로 본체 이름 · 무작위 MAC · 접속 ID · IP를 보낸다(처리방침에 적어 둠). 이걸 "수집"으로 볼지는 직접 판단 — 보수적으로 가려면 "기타 데이터 · 앱 기능용 · 사용자와 연결 안 됨"으로 적는다.
6. **서버 이용 약관(지침 5.2.2).** Wiimmfi · Kaeru WFC를 기본 목록에 넣어 두려면 각 서비스가 이런 앱에서의 이용을 허용하는지 확인한다(Delta도 서버 목록을 제공하는 선례가 있다).
7. **연령 등급 질문지 · 스크린샷**(App Store Connect가 요구하는 크기 — 폴더블 크기가 있으면 그것부터). 접은 화면 · 펼친 화면 그림은 듀오 · 듀오 시뮬레이터에서 찍는다.
8. **심사 메모(Review Notes)** — 아래 초안.

## 심사 메모 초안(영문)

> DuoS is an emulator for a retro handheld console. It contains no commercial game ROMs, BIOS, or firmware; it uses the open-source melonDS core (GPL-3.0) with its free BIOS replacement and a generated firmware. Users import games they own through the Files app.
>
> To try it without any game: a homebrew demo cartridge we wrote ourselves ("DuoS 데모") is preinstalled. On a regular iPhone, tap "여기서 카트리지 고르기" (Choose a cartridge) on the bottom screen, then tap the demo cartridge. The demo shows a 3D triangle (D-pad moves it, A/B/X/Y change color), a touch drawing pad, a microphone meter, and plays a tone when A is pressed.
>
> The app is designed for the foldable iPhone: when folded, the outer screen shows the back of the console (tap the slot to insert a cartridge, tap the battery cover for settings); when unfolded it shows the open console. On non-foldable devices it always shows the open console.
>
> Optional online play connects the emulated game to third-party community servers the user selects (off can be chosen at any time). Optional local play uses the local network to talk to other devices running DuoS.

## App Store 설명 초안

닌텐도 상표는 "무엇과 호환되는지" 사실로만, 맨 끝에 관계없음을 밝힌다(이름 · 아이콘 · 부제에는 쓰지 않는다).

> **DuoS — 접는 아이폰을 휴대용 게임기로**
>
> 접으면 게임기의 뒷면, 펴면 게임기가 열립니다. 뒷면의 슬롯을 눌러 카트리지를 꽂고, 펴면 바로 시작, 접으면 그 자리가 저장됩니다.
>
> · 직접 가진 게임 파일(.nds)을 파일 앱에서 가져와 실행
> · 3D 해상도 최대 4배, MetalFX 확대, LCD 격자 · 색감 · 잔상
> · 같은 Wi-Fi의 친구와 근거리 대전 · 협력
> · 커뮤니티 서버를 통한 온라인 플레이(선택)
> · 컨트롤러 지원
>
> 게임은 들어 있지 않습니다. 직접 가진 게임만 쓰세요.
> 오픈 소스 melonDS(GPL-3.0)를 바탕으로 만들었습니다.
>
> Nintendo DS는 Nintendo의 상표입니다. DuoS는 Nintendo와 관계가 없으며 Nintendo가 보증하지 않습니다.
