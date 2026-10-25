import Foundation

/// 사용자 설정(UserDefaults). 화면 필터 · 본체 색 등은 바로 바뀌고, DS 본체 설정(이름 · 언어 등)은 다음에 카트리지를 꽂을 때부터.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("DuoDSSettingsDidChange")

    /// 펼친 DS의 배치: 실기기(DS Lite) 비율 / 화면을 크게
    enum LayoutStyle: Int, CaseIterable {
        case real = 0, large
        var title: String { self == .real ? "실기기 비율" : "화면 크게" }
    }

    /// 확대 방식 — ScreenLook.Upscale과 같은 번호
    enum Filter: Int, CaseIterable {
        case sharp = 0, smooth, pixel, pixelArt, metalFX
        var title: String {
            switch self {
            case .sharp: return "선명하게"
            case .smooth: return "부드럽게"
            case .pixel: return "픽셀 그대로"
            case .pixelArt: return "도트 다듬기(Scale4x)"
            case .metalFX: return "MetalFX(권장)"
            }
        }
        /// 이 기기에서 고를 수 있는 것(MetalFX는 되는 기기만)
        static var available: [Filter] { allCases.filter { $0 != .metalFX || ScreenPipeline.metalFXAvailable } }
    }

    /// 색감 — ScreenLook.Tone과 같은 번호
    enum Tone: Int, CaseIterable {
        case original = 0, vivid, soft
        var title: String { ["원본", "생생하게", "차분하게"][rawValue] }
    }

    /// 3D 내부 해상도 — 3D 폴리곤을 이만큼 높은 해상도로 다시 그린다(2D 그림 · 화면 캡처는 256 × 192 그대로)
    enum Scale3D: Int, CaseIterable {
        case x1 = 1, x2, x3, x4
        var title: String { self == .x1 ? "1×(원본)" : "\(rawValue)×" }
    }

    /// LCD 격자 세기
    enum Grid: Int, CaseIterable {
        case off = 0, light, strong
        var title: String { ["끄기", "약하게", "강하게"][rawValue] }
        var strength: Float { [0, 0.12, 0.25][rawValue] }
    }

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "nickname": "Duo",
            "language": 1,
            "favoriteColor": 11,
            "birthdayMonth": 1,
            "birthdayDay": 1,
            "volume": 1.0,
            "filter": (ScreenPipeline.metalFXAvailable ? Filter.metalFX : Filter.sharp).rawValue,
            "scale3D": Scale3D.x1.rawValue,
            "haptics": true,
            "showFps": false,
            "theme": ConsoleTheme.polarWhite.id,
            "foldedFlip": false,
            "layoutStyle": LayoutStyle.real.rawValue,
            "lanMax": 4,
            "wfcServer": Internet.Server.wiimmfi.rawValue,
        ])
    }

    private func changed() { NotificationCenter.default.post(name: Settings.didChange, object: self) }

    var nickname: String { get { d.string(forKey: "nickname") ?? "Duo" } set { d.set(String(newValue.prefix(10)), forKey: "nickname"); changed() } }
    /// DS_LANG_* (0 일본어 · 1 영어 · 2 프랑스어 · 3 독일어 · 4 이탈리아어 · 5 스페인어)
    var language: Int { get { d.integer(forKey: "language") } set { d.set(newValue, forKey: "language"); changed() } }
    var favoriteColor: Int { get { d.integer(forKey: "favoriteColor") } set { d.set(newValue, forKey: "favoriteColor"); changed() } }
    var birthdayMonth: Int { get { d.integer(forKey: "birthdayMonth") } set { d.set(newValue, forKey: "birthdayMonth"); changed() } }
    var birthdayDay: Int { get { d.integer(forKey: "birthdayDay") } set { d.set(newValue, forKey: "birthdayDay"); changed() } }
    var volume: Float { get { d.float(forKey: "volume") } set { d.set(newValue, forKey: "volume"); changed() } }
    var filter: Filter { get { Filter(rawValue: d.integer(forKey: "filter")) ?? .sharp } set { d.set(newValue.rawValue, forKey: "filter"); changed() } }
    var scale3D: Scale3D { get { Scale3D(rawValue: d.integer(forKey: "scale3D")) ?? .x1 } set { d.set(newValue.rawValue, forKey: "scale3D"); changed() } }
    var tone: Tone { get { Tone(rawValue: d.integer(forKey: "tone")) ?? .original } set { d.set(newValue.rawValue, forKey: "tone"); changed() } }
    var lcdGrid: Grid { get { Grid(rawValue: d.integer(forKey: "lcdGrid")) ?? .off } set { d.set(newValue.rawValue, forKey: "lcdGrid"); changed() } }
    /// 잔상(지난 프레임과 반씩 섞기)
    var frameBlend: Bool { get { d.bool(forKey: "frameBlend") } set { d.set(newValue, forKey: "frameBlend"); changed() } }
    /// 화면 그리기 설정 한 묶음
    var screenLook: ScreenLook {
        ScreenLook(upscale: ScreenLook.Upscale(rawValue: filter.rawValue) ?? .sharp, tone: ScreenLook.Tone(rawValue: tone.rawValue) ?? .original,
                   grid: lcdGrid.strength, frameBlend: frameBlend)
    }
    var haptics: Bool { get { d.bool(forKey: "haptics") } set { d.set(newValue, forKey: "haptics"); changed() } }
    var showFps: Bool { get { d.bool(forKey: "showFps") } set { d.set(newValue, forKey: "showFps"); changed() } }
    /// 본체 색(ConsoleTheme.id)
    var themeID: String { get { d.string(forKey: "theme") ?? ConsoleTheme.polarWhite.id } set { d.set(newValue, forKey: "theme"); changed() } }
    /// 접었을 때 화면을 180° 뒤집기(카드 슬롯이 경첩 반대쪽에 보이면)
    var foldedFlip: Bool { get { d.bool(forKey: "foldedFlip") } set { d.set(newValue, forKey: "foldedFlip"); changed() } }
    var layoutStyle: LayoutStyle { get { LayoutStyle(rawValue: d.integer(forKey: "layoutStyle")) ?? .real } set { d.set(newValue.rawValue, forKey: "layoutStyle"); changed() } }
    /// DS 무선 주소(MAC) — 처음 한 번 무작위로 만들어 둔다(닌텐도 OUI 00:09:BF + 3바이트). 기기마다 달라야 근거리 통신에서 서로를 구분한다
    var macAddress: [UInt8] {
        if let d = d.data(forKey: "mac"), d.count == 6 { return [UInt8](d) }
        let mac: [UInt8] = [0x00, 0x09, 0xBF, UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255)]
        d.set(Data(mac), forKey: "mac")
        return mac
    }
    /// 무선 방을 만들 때의 최대 인원
    var lanMaxPlayers: Int { get { max(2, d.integer(forKey: "lanMax")) } set { d.set(newValue, forKey: "lanMax") } }
    /// 인터넷(Nintendo WFC 대체 서버). 바꾸면 Internet.apply()로 코어에 알린다
    var wfcServer: Internet.Server {
        get { Internet.Server(rawValue: d.string(forKey: "wfcServer") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "wfcServer"); changed() }
    }
    /// 직접 입력한 서버 DNS(IPv4)
    var wfcCustomDNS: String { get { d.string(forKey: "wfcCustomDNS") ?? "" } set { d.set(newValue, forKey: "wfcCustomDNS") } }
    /// 꽂혀 있는 카트리지(ROM 파일 이름) — 앱을 다시 켜도 그대로
    var insertedCartridge: String? { get { d.string(forKey: "insertedCartridge") } set { d.set(newValue, forKey: "insertedCartridge") } }

    /// GPL-3.0 소스 공개 주소(설정 › 정보 › 소스 코드)
    static let sourceCodeURL = URL(string: "https://github.com/MiyeoukMan/duos")

    static let languageNames = ["日本語", "English", "Français", "Deutsch", "Italiano", "Español"]
}
