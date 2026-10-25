import UIKit

/// 펼친 DS의 몸(움직이지 않는 부분): 뚜껑 · 바닥 판, 화면 테, 스피커 구멍, 경첩, 인쇄 글씨.
/// 버튼은 ControlsView, 화면은 Metal(ScreenRenderer), 불빛은 LEDView가 위에 그린다.
final class OpenBodyView: UIView {
    var layout = Layout() { didSet { setNeedsDisplay() } }
    var theme = ConsoleTheme.current { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let t = theme
        let L = layout

        // 뚜껑 · 바닥 판: 반짝이는 플라스틱(위가 밝고 아래로 살짝 어두워짐)
        let lid = UIBezierPath(rect: L.lid)
        Paint.linear(ctx, lid, [t.face.lighter(0.25), t.face, t.faceShade], from: CGPoint(x: 0, y: L.lid.minY), to: CGPoint(x: 0, y: L.lid.maxY))
        let base = UIBezierPath(rect: L.base)
        Paint.linear(ctx, base, [t.face, t.faceShade.mixed(with: t.face, 0.4)], from: CGPoint(x: 0, y: L.base.minY), to: CGPoint(x: 0, y: L.base.maxY))
        // 뚜껑의 비스듬한 광택
        let gloss = UIBezierPath()
        gloss.move(to: CGPoint(x: L.lid.width * 0.55, y: L.lid.minY))
        gloss.addLine(to: CGPoint(x: L.lid.width * 0.80, y: L.lid.minY))
        gloss.addLine(to: CGPoint(x: L.lid.width * 0.45, y: L.lid.maxY))
        gloss.addLine(to: CGPoint(x: L.lid.width * 0.20, y: L.lid.maxY))
        gloss.close()
        UIColor(white: 1, alpha: t.isLight ? 0.22 : 0.05).setFill()
        gloss.fill()

        // 화면 테(검은 유리 띠) — 판에 살짝 파묻힌 느낌으로 그림자
        for screen in [L.top, L.bottom] where screen.width > 0 {
            let frame = screen.insetBy(dx: -10, dy: -10)
            let recess = UIBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3), cornerRadius: 12)
            t.faceShade.darker(t.isLight ? 0.06 : 0.3).setFill()
            recess.fill()
            let bezel = UIBezierPath(roundedRect: frame, cornerRadius: 9)
            Paint.shadow(ctx, UIColor(white: 0, alpha: t.isLight ? 0.35 : 0.6), blur: 4, offset: CGSize(width: 0, height: 1)) {
                t.bezel.setFill()
                bezel.fill()
            }
            // 유리 위 은은한 반사
            Paint.linear(ctx, bezel, [UIColor(white: 1, alpha: 0.10), UIColor(white: 1, alpha: 0.0)],
                         from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.minX + frame.width * 0.3, y: frame.maxY))
            UIColor(white: 1, alpha: 0.08).setStroke()
            bezel.lineWidth = 1
            bezel.stroke()
        }

        // 스피커 구멍(육각 배열)
        for c in [L.speakerLeft, L.speakerRight] where c != .zero {
            drawSpeaker(ctx, center: c, radius: min(L.speakerRadius, (L.top.minX - 8) / 2))
        }

        drawHinge(ctx, L.hinge)

        // 인쇄 글씨
        let small: CGFloat = 9
        for (r, s, outerRight) in [(L.select, "SELECT", true), (L.start, "START", true), (L.settings, "SETTINGS", false), (L.mic, "MIC", false)] where r.width > 0 {
            if L.labelsBeside {
                // 버튼 옆 바깥쪽(판 가장자리 쪽)에 인쇄 — 화면 쪽은 테에 가린다
                let w = (s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: small, weight: .bold), .kern: 0.8]).width
                let x = outerRight ? r.maxX + 7 + w / 2 : r.minX - 7 - w / 2
                Paint.text(s, at: CGPoint(x: x, y: r.midY), size: small, weight: .bold, color: t.print, kern: 0.8)
            } else {
                Paint.text(s, at: CGPoint(x: r.midX, y: r.maxY + 10), size: small, weight: .bold, color: t.print, kern: 0.8)
            }
        }
    }

    private func drawSpeaker(_ ctx: CGContext, center c: CGPoint, radius: CGFloat) {
        let hole: CGFloat = 2.3
        let step: CGFloat = 7.4
        let holeColor = theme.isLight ? UIColor(white: 0.22, alpha: 0.85) : UIColor(white: 0, alpha: 0.9)
        var row = 0
        var y = -radius
        while y <= radius {
            let offset = row % 2 == 0 ? 0 : step / 2
            var x = -radius + offset
            while x <= radius {
                if hypot(x, y) <= radius - hole {
                    let p = CGPoint(x: c.x + x, y: c.y + y)
                    let r = CGRect(x: p.x - hole, y: p.y - hole, width: hole * 2, height: hole * 2)
                    UIColor(white: 1, alpha: theme.isLight ? 0.9 : 0.12).setFill()
                    UIBezierPath(ovalIn: r.offsetBy(dx: 0, dy: 0.8)).fill()
                    holeColor.setFill()
                    UIBezierPath(ovalIn: r).fill()
                }
                x += step
            }
            y += step * 0.866
            row += 1
        }
    }

    private func drawHinge(_ ctx: CGContext, _ h: CGRect) {
        guard h.height > 0 else { return }
        let t = theme
        // 판과 경첩 사이의 어두운 틈
        t.seam.darker(0.2).setFill()
        UIBezierPath(rect: h).fill()
        // 원통: 가장자리 조금 안쪽까지
        let body = UIBezierPath(roundedRect: h.insetBy(dx: 6, dy: 2), cornerRadius: (h.height - 4) / 2)
        Paint.linear(ctx, body, [t.hingeShade, t.hinge.lighter(0.35), t.hinge, t.hingeShade],
                     from: CGPoint(x: 0, y: h.minY + 2), to: CGPoint(x: 0, y: h.maxY - 2))
        // 원통을 나누는 홈(가운데 마디)
        let seg = h.width * 0.18
        for x in [h.midX - seg, h.midX + seg] {
            t.seam.withAlphaComponent(0.6).setFill()
            UIBezierPath(rect: CGRect(x: x - 0.5, y: h.minY + 3, width: 1, height: h.height - 6)).fill()
        }
        // 마이크 구멍
        let m = CGPoint(x: h.midX, y: h.midY)
        UIColor(white: 0, alpha: 0.75).setFill()
        UIBezierPath(ovalIn: CGRect(x: m.x - 2.6, y: m.y - 2.6, width: 5.2, height: 5.2)).fill()
        Paint.text("MIC", at: CGPoint(x: m.x + 18, y: m.y), size: 6.5, weight: .bold, color: t.print.withAlphaComponent(0.8), kern: 0.6)
    }
}

/// 경첩의 전원 · 충전 불빛. 전원은 게임 중 초록(배터리가 적으면 빨강), 쉬는 중엔 깜빡임. 충전 불빛은 아이폰이 충전 중일 때.
final class LEDView: UIView {
    enum Power { case off, on, sleeping }

    var power: Power = .off { didSet { update() } }
    /// 근거리 무선 중(초대 DS의 무선 불빛처럼 주황 — 천천히 숨 쉰다)
    var wireless = false { didSet { if wireless != oldValue { update() } } }
    private let powerDot = CALayer()
    private let chargeDot = CALayer()
    private let wirelessDot = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for d in [powerDot, chargeDot, wirelessDot] {
            d.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            d.cornerRadius = 3
            d.shadowOpacity = 0.9
            d.shadowRadius = 4
            d.shadowOffset = .zero
            layer.addSublayer(d)
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    func place(power p: CGPoint, charge c: CGPoint) {
        powerDot.position = p
        chargeDot.position = c
        wirelessDot.position = CGPoint(x: p.x - (c.x - p.x), y: p.y)   // 전원 불빛 왼쪽
    }

    @objc private func update() {
        let level = UIDevice.current.batteryLevel
        let low = level >= 0 && level < 0.15
        let on = UIColor(hex: low ? 0xFF3B30 : 0x3DFF6A)
        let dim = UIColor(white: 0.35, alpha: 0.6)
        powerDot.removeAllAnimations()
        switch power {
        case .off:
            powerDot.backgroundColor = dim.cgColor
            powerDot.shadowColor = UIColor.clear.cgColor
        case .on:
            powerDot.backgroundColor = on.cgColor
            powerDot.shadowColor = on.cgColor
        case .sleeping:
            powerDot.backgroundColor = on.cgColor
            powerDot.shadowColor = on.cgColor
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0.08
            blink.duration = 1.1
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            powerDot.add(blink, forKey: "blink")
        }
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full
        let orange = UIColor(hex: 0xFF9F0A)
        chargeDot.backgroundColor = (charging ? orange : dim).cgColor
        chargeDot.shadowColor = (charging ? orange : .clear).cgColor
        let amber = UIColor(hex: 0xFFB020)
        wirelessDot.removeAllAnimations()
        wirelessDot.backgroundColor = (wireless ? amber : dim).cgColor
        wirelessDot.shadowColor = (wireless ? amber : .clear).cgColor
        if wireless {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 0.6
            a.autoreverses = true
            a.repeatCount = .infinity
            wirelessDot.add(a, forKey: "breathe")
        }
    }
}
