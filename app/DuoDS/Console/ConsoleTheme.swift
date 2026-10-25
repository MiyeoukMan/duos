import UIKit

/// 본체 색. DS Lite의 대표 색들을 본떴다(겉 = 접었을 때 보이는 껍데기, 안 = 펼쳤을 때 화면 둘레).
/// 닌텐도 로고 · 상표는 그리지 않는다.
struct ConsoleTheme {
    let id: String
    let name: String
    /// 겉 껍데기(뒷면 · 뚜껑 바깥)
    let shell: UIColor
    let shellShade: UIColor
    /// 안쪽 면(화면 둘레)
    let face: UIColor
    let faceShade: UIColor
    /// 화면을 감싼 검은 테
    let bezel: UIColor
    /// 버튼
    let button: UIColor
    let buttonShade: UIColor
    let letter: UIColor
    /// 인쇄 글씨(START · SELECT 등)
    let print: UIColor
    /// 경첩
    let hinge: UIColor
    let hingeShade: UIColor
    /// 이음매 · 홈(어두운 선)
    let seam: UIColor

    static let all: [ConsoleTheme] = [polarWhite, jetBlack, iceBlue, crimson, cobalt, coralPink]

    static func named(_ id: String) -> ConsoleTheme { all.first { $0.id == id } ?? polarWhite }
    static var current: ConsoleTheme { named(Settings.shared.themeID) }

    static let polarWhite = ConsoleTheme(
        id: "polarWhite", name: "폴라 화이트",
        shell: UIColor(hex: 0xF4F4F1), shellShade: UIColor(hex: 0xDCDDD9),
        face: UIColor(hex: 0xF7F7F5), faceShade: UIColor(hex: 0xE6E7E3),
        bezel: UIColor(hex: 0x1B1C1F),
        button: UIColor(hex: 0xF1F1EE), buttonShade: UIColor(hex: 0xC9CAC6), letter: UIColor(hex: 0x9EA1A6),
        print: UIColor(hex: 0xA3A6AB),
        hinge: UIColor(hex: 0xE9EAE7), hingeShade: UIColor(hex: 0xB9BBBA),
        seam: UIColor(hex: 0xB4B6B4))

    static let jetBlack = ConsoleTheme(
        id: "jetBlack", name: "제트 블랙",
        shell: UIColor(hex: 0x26272B), shellShade: UIColor(hex: 0x111214),
        face: UIColor(hex: 0x232428), faceShade: UIColor(hex: 0x16171A),
        bezel: UIColor(hex: 0x050506),
        button: UIColor(hex: 0x34353A), buttonShade: UIColor(hex: 0x141518), letter: UIColor(hex: 0x8C8F95),
        print: UIColor(hex: 0x7D8086),
        hinge: UIColor(hex: 0x3A3B40), hingeShade: UIColor(hex: 0x141518),
        seam: UIColor(hex: 0x09090A))

    static let iceBlue = ConsoleTheme(
        id: "iceBlue", name: "아이스 블루",
        shell: UIColor(hex: 0xA9D3EE), shellShade: UIColor(hex: 0x7FB0D3),
        face: UIColor(hex: 0xF5F7F8), faceShade: UIColor(hex: 0xE2E6E9),
        bezel: UIColor(hex: 0x1B1C1F),
        button: UIColor(hex: 0xF1F3F4), buttonShade: UIColor(hex: 0xC5CBD0), letter: UIColor(hex: 0x8FA6B8),
        print: UIColor(hex: 0x98A9B6),
        hinge: UIColor(hex: 0xB3D9F1), hingeShade: UIColor(hex: 0x6E9FC2),
        seam: UIColor(hex: 0x86A9C2))

    static let crimson = ConsoleTheme(
        id: "crimson", name: "크림슨 / 블랙",
        shell: UIColor(hex: 0xC21A2E), shellShade: UIColor(hex: 0x7E0E1B),
        face: UIColor(hex: 0x232428), faceShade: UIColor(hex: 0x15161A),
        bezel: UIColor(hex: 0x050506),
        button: UIColor(hex: 0x303136), buttonShade: UIColor(hex: 0x111215), letter: UIColor(hex: 0x8D9096),
        print: UIColor(hex: 0x7E8187),
        hinge: UIColor(hex: 0xC8233A), hingeShade: UIColor(hex: 0x6E0B17),
        seam: UIColor(hex: 0x0A0A0C))

    static let cobalt = ConsoleTheme(
        id: "cobalt", name: "코발트 / 블랙",
        shell: UIColor(hex: 0x2152B8), shellShade: UIColor(hex: 0x123274),
        face: UIColor(hex: 0x232428), faceShade: UIColor(hex: 0x15161A),
        bezel: UIColor(hex: 0x050506),
        button: UIColor(hex: 0x303136), buttonShade: UIColor(hex: 0x111215), letter: UIColor(hex: 0x8D9096),
        print: UIColor(hex: 0x7E8187),
        hinge: UIColor(hex: 0x2A5CC4), hingeShade: UIColor(hex: 0x10295E),
        seam: UIColor(hex: 0x0A0A0C))

    static let coralPink = ConsoleTheme(
        id: "coralPink", name: "코랄 핑크",
        shell: UIColor(hex: 0xF6B3C2), shellShade: UIColor(hex: 0xE08AA0),
        face: UIColor(hex: 0xF8F6F6), faceShade: UIColor(hex: 0xE9E3E4),
        bezel: UIColor(hex: 0x1B1C1F),
        button: UIColor(hex: 0xF4F1F1), buttonShade: UIColor(hex: 0xCDC5C7), letter: UIColor(hex: 0xB0959C),
        print: UIColor(hex: 0xB59EA4),
        hinge: UIColor(hex: 0xF7BAC8), hingeShade: UIColor(hex: 0xC97A8E),
        seam: UIColor(hex: 0xD592A4))

    /// 밝은 본체인가(글씨 · 그림자 세기를 고른다)
    var isLight: Bool {
        var w: CGFloat = 0
        face.getWhite(&w, alpha: nil)
        return w > 0.5
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// t만큼 섞기
    func mixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }

    func lighter(_ t: CGFloat) -> UIColor { mixed(with: .white, t) }
    func darker(_ t: CGFloat) -> UIColor { mixed(with: .black, t) }
}

/// 그리기 도우미
enum Paint {
    static func linear(_ ctx: CGContext, _ path: UIBezierPath, _ colors: [UIColor], from: CGPoint, to: CGPoint) {
        ctx.saveGState()
        path.addClip()
        let cg = colors.map { $0.cgColor } as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cg, locations: nil) {
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    static func radial(_ ctx: CGContext, _ path: UIBezierPath, _ colors: [UIColor], center: CGPoint, radius: CGFloat) {
        ctx.saveGState()
        path.addClip()
        let cg = colors.map { $0.cgColor } as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cg, locations: nil) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    static func shadow(_ ctx: CGContext, _ color: UIColor, blur: CGFloat, offset: CGSize = .zero, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: color.cgColor)
        body()
        ctx.restoreGState()
    }

    static func text(_ s: String, at c: CGPoint, size: CGFloat, weight: UIFont.Weight = .semibold, color: UIColor,
                     rounded: Bool = true, kern: CGFloat = 0, center: Bool = true) {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = rounded ? (base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base) : base
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let sz = (s as NSString).size(withAttributes: attr)
        let origin = center ? CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2) : c
        (s as NSString).draw(at: origin, withAttributes: attr)
    }
}
