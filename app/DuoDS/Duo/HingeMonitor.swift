import UIKit

/// 아이폰 듀오의 접힘 상태(iOS 27.1 UIHingeInteraction — 상태와 각도만 알려 주고 접힌 선의 자리는 안 알려 준다).
/// 접히지 않는 기기 · iOS 27.1 밑에서는 `.unavailable`.
/// 시험용: 실행 인자 `-DuoHinge partial|open|closed`(시뮬레이터는 접힘이 없다)와 `-DuoHingeAngle 도`.
final class HingeMonitor {
    enum Status: Equatable {
        case unavailable, unknown, closed, partial, open
    }

    private(set) var status: Status = .unavailable
    /// 도(0 닫힘 · 180 쫙 폄)
    private(set) var angle: Double = 180
    var onChange: (() -> Void)?

    private var interaction: AnyObject?

    /// 이 기기가 아이폰 듀오인가(시뮬레이터 포함) — 접힘 정보가 잠깐 없을 때 화면 크기로 짐작하는 건 듀오에서만
    static let isDuo: Bool = {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var u = utsname()
            uname(&u)
            id = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return id == "iPhone19,4"
    }()

    /// 접히는 아이폰인가: 듀오(모델 번호)이거나, 한 번이라도 경첩 정보를 받은 기기(다른 폴더블 아이폰도 — 한 번 받으면 기억한다).
    /// App Store에는 "접히는 기기만" 깔게 하는 장치 조건 키가 없어서, 접히지 않는 기기에서도 펼친 DS로 돌게 둔다
    static var isFoldable: Bool { isDuo || UserDefaults.standard.bool(forKey: "hingeSeen") }

    /// 접을 수 있는 기기인가 — 안내 글 · 접힘 짐작에
    var canFold: Bool { Self.isFoldable || status == .closed || status == .partial || status == .open }

    /// 반쯤 접힌 DS 자세인가(대략 40° ~ 160°)
    var isBent: Bool { status == .partial && angle >= 30 && angle <= 165 }

    /// 시험용(시뮬레이터엔 접힘이 없다): 상태를 흉내 낸다
    func simulate(_ s: Status) {
        status = s
        angle = s == .closed ? 0 : s == .partial ? 110 : 180
        onChange?()
    }

    func attach(to view: UIView) {
        if let forced = UserDefaults.standard.string(forKey: "DuoHinge") {
            switch forced {
            case "partial": status = .partial; angle = 110
            case "open": status = .open; angle = 180
            case "closed": status = .closed; angle = 0
            default: break
            }
            let a = UserDefaults.standard.double(forKey: "DuoHingeAngle")
            if a > 0 { angle = a }
            onChange?()
            return
        }
        guard #available(iOS 27.1, *) else { return }
        let i = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            if let hinge = update.hinge {
                UserDefaults.standard.set(true, forKey: "hingeSeen")
                switch hinge.status {
                case .closed: self.status = .closed
                case .partiallyOpen: self.status = .partial
                case .fullyOpen: self.status = .open
                default: self.status = .unknown
                }
                self.angle = Double(hinge.angle) * 180 / .pi
            } else {
                self.status = .unknown   // 접힘을 알려 주는 화면 계층을 떠났다
            }
            self.onChange?()
        }
        view.addInteraction(i)
        interaction = i
    }
}
