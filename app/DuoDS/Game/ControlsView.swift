import UIKit

/// 펼친 DS의 버튼과 터치 화면을 함께 받는 투명한 판(여러 손가락). 버튼은 DS Lite처럼 그린다(볼록한 원 · 십자 · 어깨).
/// 손가락마다 처음 닿은 곳(십자키 · ABXY · L · R · START · SELECT · SETTINGS · MIC · 터치 화면)에 묶이고, 뗄 때까지 그곳만 움직인다.
/// 십자키는 8방향, ABXY는 두 버튼 사이를 누르면 둘 다(예: A+B).
final class ControlsView: UIView {
    enum Region { case dpad, face, l, r, start, select, settings, mic, screen }

    var layout = Layout() { didSet { setNeedsDisplay() } }
    var theme = ConsoleTheme.current { didSet { setNeedsDisplay() } }
    /// DS 아래 화면이 그려진 자리(위 · 아래를 바꾸면 위 자리). 비어 있으면 터치 화면을 받지 않는다
    var touchRect = CGRect.zero
    var onKeys: ((UInt32) -> Void)?
    var onTouch: ((CGPoint?) -> Void)?
    var onSettings: (() -> Void)?
    var onMic: ((Bool) -> Void)?

    private var owners: [UITouch: Region] = [:]
    private var keys: UInt32 = 0
    private var micOn = false
    private var settingsDown = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 손가락을 다 떼게 한다(창을 열 때 · 접을 때)
    func releaseAll() {
        owners.removeAll()
        settingsDown = false
        update()
        setNeedsDisplay()
    }

    // ── 터치 ─────────────────────────────────

    private func region(at p: CGPoint) -> Region? {
        if !touchRect.isEmpty && touchRect.contains(p) { return .screen }
        let candidates: [(Region, CGRect)] = [
            (.dpad, layout.dpad.insetBy(dx: -24, dy: -24)),
            (.face, layout.face.insetBy(dx: -24, dy: -24)),
            (.l, layout.l.insetBy(dx: -10, dy: -10)),
            (.r, layout.r.insetBy(dx: -10, dy: -10)),
            (.start, layout.start.insetBy(dx: -6, dy: -14)),
            (.select, layout.select.insetBy(dx: -6, dy: -14)),
            (.settings, layout.settings.insetBy(dx: -6, dy: -14)),
            (.mic, layout.mic.insetBy(dx: -6, dy: -14)),
        ]
        // 겹치면 가운데가 더 가까운 쪽. 크기 0인 자리는 뺀다
        return candidates.filter { $0.1.width > 40 && $0.1.contains(p) }
            .min { hypot($0.1.midX - p.x, $0.1.midY - p.y) < hypot($1.1.midX - p.x, $1.1.midY - p.y) }?.0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let r = region(at: t.location(in: self)) else { continue }
            if r == .screen, owners.values.contains(.screen) { continue }   // 터치 화면은 한 손가락만
            owners[t] = r
            if r == .settings {
                settingsDown = true
                if Settings.shared.haptics { haptic.impactOccurred(intensity: 0.7) }
                setNeedsDisplay()
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update() }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if owners[t] == .settings {
                settingsDown = false
                setNeedsDisplay()
                if layout.settings.insetBy(dx: -20, dy: -20).contains(t.location(in: self)) { onSettings?() }
            }
            owners[t] = nil
        }
        update()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        owners.removeAll()
        settingsDown = false
        update()
        setNeedsDisplay()
    }

    private func update() {
        var k: UInt32 = 0
        var touch: CGPoint?
        var mic = false
        for (t, r) in owners {
            let p = t.location(in: self)
            switch r {
            case .dpad: k |= dpadKeys(p)
            case .face: k |= faceKeys(p)
            case .l: k |= UInt32(DS_KEY_L)
            case .r: k |= UInt32(DS_KEY_R)
            case .start: k |= UInt32(DS_KEY_START)
            case .select: k |= UInt32(DS_KEY_SELECT)
            case .mic: mic = true
            case .settings: break
            case .screen:
                let x = (p.x - touchRect.minX) / touchRect.width * CGFloat(DS_SCREEN_WIDTH)
                let y = (p.y - touchRect.minY) / touchRect.height * CGFloat(DS_SCREEN_HEIGHT)
                touch = CGPoint(x: min(max(x, 0), CGFloat(DS_SCREEN_WIDTH - 1)), y: min(max(y, 0), CGFloat(DS_SCREEN_HEIGHT - 1)))
            }
        }
        if k != keys {
            if k & ~keys != 0, Settings.shared.haptics { haptic.impactOccurred(intensity: 0.7) }
            keys = k
            onKeys?(k)
            setNeedsDisplay()
        }
        if mic != micOn {
            micOn = mic
            onMic?(mic)
            setNeedsDisplay()
        }
        onTouch?(touch)
    }

    private func dpadKeys(_ p: CGPoint) -> UInt32 {
        let c = CGPoint(x: layout.dpad.midX, y: layout.dpad.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        if hypot(dx, dy) < layout.dpad.width * 0.12 { return 0 }
        let a = atan2(-dy, dx) * 180 / .pi   // 0 = 오른쪽, 90 = 위
        var k: UInt32 = 0
        if abs(a) < 67.5 { k |= UInt32(DS_KEY_RIGHT) }
        if abs(a) > 112.5 { k |= UInt32(DS_KEY_LEFT) }
        if a > 22.5 && a < 157.5 { k |= UInt32(DS_KEY_UP) }
        if a < -22.5 && a > -157.5 { k |= UInt32(DS_KEY_DOWN) }
        return k
    }

    private var faceButtons: [(UInt32, CGPoint, String)] {
        let f = layout.face, o = f.width * 0.32
        return [
            (UInt32(DS_KEY_A), CGPoint(x: f.midX + o, y: f.midY), "A"),
            (UInt32(DS_KEY_B), CGPoint(x: f.midX, y: f.midY + o), "B"),
            (UInt32(DS_KEY_X), CGPoint(x: f.midX, y: f.midY - o), "X"),
            (UInt32(DS_KEY_Y), CGPoint(x: f.midX - o, y: f.midY), "Y"),
        ]
    }

    private func faceKeys(_ p: CGPoint) -> UInt32 {
        let sorted = faceButtons.map { ($0.0, hypot($0.1.x - p.x, $0.1.y - p.y)) }.sorted { $0.1 < $1.1 }
        var k = sorted[0].0
        // 두 버튼의 거의 한가운데면 둘 다
        if sorted[1].1 < sorted[0].1 * 1.3 && sorted[1].1 < layout.face.width * 0.36 { k |= sorted[1].0 }
        return k
    }

    // ── 그리기(DS Lite 버튼) ──────────────────

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), layout.dpad.width > 0 else { return }
        drawDpad(ctx)
        let rad = layout.face.width * 0.165
        for (bit, c, name) in faceButtons {
            drawRoundButton(ctx, center: c, radius: rad, label: name, pressed: keys & bit != 0)
        }
        drawShoulder(ctx, layout.l, "L", pressed: keys & UInt32(DS_KEY_L) != 0, left: true)
        drawShoulder(ctx, layout.r, "R", pressed: keys & UInt32(DS_KEY_R) != 0, left: false)
        drawSmall(ctx, layout.select, pressed: keys & UInt32(DS_KEY_SELECT) != 0)
        drawSmall(ctx, layout.start, pressed: keys & UInt32(DS_KEY_START) != 0)
        drawSmall(ctx, layout.settings, pressed: settingsDown)
        drawSmall(ctx, layout.mic, pressed: micOn)
    }

    /// 볼록한 플라스틱: 아래로 떨어지는 그림자 + 위가 밝은 그러데이션. 누르면 그림자가 줄고 살짝 내려앉는다
    private func convex(_ ctx: CGContext, _ path: UIBezierPath, _ bounds: CGRect, pressed: Bool, base: UIColor? = nil) {
        let t = theme
        let color = base ?? t.button
        let sink: CGFloat = pressed ? 1.2 : 0
        let p = path.copy() as! UIBezierPath
        p.apply(CGAffineTransform(translationX: 0, y: sink))
        Paint.shadow(ctx, UIColor(white: 0, alpha: t.isLight ? 0.32 : 0.65), blur: pressed ? 1.5 : 4, offset: CGSize(width: 0, height: pressed ? 0.5 : 2.2)) {
            color.setFill()
            p.fill()
        }
        let top = pressed ? color.mixed(with: t.buttonShade, 0.45) : color.lighter(t.isLight ? 0.5 : 0.12)
        let bottom = pressed ? color.mixed(with: t.buttonShade, 0.7) : color.mixed(with: t.buttonShade, 0.55)
        Paint.linear(ctx, p, [top, color, bottom], from: CGPoint(x: bounds.minX, y: bounds.minY + sink), to: CGPoint(x: bounds.minX, y: bounds.maxY + sink))
        t.buttonShade.withAlphaComponent(0.8).setStroke()
        p.lineWidth = 0.8
        p.stroke()
    }

    private func drawRoundButton(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, label: String, pressed: Bool) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        // 판에 뚫린 구멍(둘레의 어두운 고리)
        theme.faceShade.darker(theme.isLight ? 0.12 : 0.4).setFill()
        UIBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5)).fill()
        convex(ctx, UIBezierPath(ovalIn: rect), rect, pressed: pressed)
        Paint.text(label, at: CGPoint(x: c.x, y: c.y + (pressed ? 1.2 : 0)), size: r * 0.95, weight: .bold, color: theme.letter)
    }

    private func drawDpad(_ ctx: CGContext) {
        let d = layout.dpad, arm = d.width * 0.34
        let h = arm / 2, x0 = d.minX + 4, x1 = d.maxX - 4, y0 = d.minY + 4, y1 = d.maxY - 4, cx = d.midX, cy = d.midY
        let cross = UIBezierPath()
        cross.move(to: CGPoint(x: cx - h, y: y0))
        for (x, y) in [(cx + h, y0), (cx + h, cy - h), (x1, cy - h), (x1, cy + h), (cx + h, cy + h), (cx + h, y1),
                       (cx - h, y1), (cx - h, cy + h), (x0, cy + h), (x0, cy - h), (cx - h, cy - h)] {
            cross.addLine(to: CGPoint(x: x, y: y))
        }
        cross.close()
        // 판의 십자 구멍
        let well = cross.copy() as! UIBezierPath
        theme.faceShade.darker(theme.isLight ? 0.12 : 0.4).setStroke()
        well.lineWidth = 5
        well.lineJoinStyle = .round
        well.stroke()

        let anyPressed = keys & UInt32(DS_KEY_UP | DS_KEY_DOWN | DS_KEY_LEFT | DS_KEY_RIGHT) != 0
        convex(ctx, cross, d, pressed: false, base: theme.button.mixed(with: theme.buttonShade, 0.15))
        // 누른 쪽 팔만 어둡게(기울어진 느낌)
        if anyPressed {
            let arms: [(UInt32, CGRect)] = [
                (UInt32(DS_KEY_UP), CGRect(x: cx - h, y: y0, width: arm, height: cy - h - y0)),
                (UInt32(DS_KEY_DOWN), CGRect(x: cx - h, y: cy + h, width: arm, height: y1 - cy - h)),
                (UInt32(DS_KEY_LEFT), CGRect(x: x0, y: cy - h, width: cx - h - x0, height: arm)),
                (UInt32(DS_KEY_RIGHT), CGRect(x: cx + h, y: cy - h, width: x1 - cx - h, height: arm)),
            ]
            for (bit, r) in arms where keys & bit != 0 {
                UIColor(white: 0, alpha: theme.isLight ? 0.14 : 0.3).setFill()
                UIBezierPath(rect: r).fill()
            }
        }
        // 가운데 오목한 원 · 팔 끝의 세모 자국
        let dimple = CGRect(x: cx - h * 0.55, y: cy - h * 0.55, width: h * 1.1, height: h * 1.1)
        Paint.radial(ctx, UIBezierPath(ovalIn: dimple), [theme.buttonShade.withAlphaComponent(0.55), theme.buttonShade.withAlphaComponent(0.0)],
                     center: CGPoint(x: cx, y: cy - 1), radius: h * 0.6)
        let tri = arm * 0.15
        theme.letter.withAlphaComponent(0.55).setFill()
        for (i, c) in [CGPoint(x: cx, y: y0 + arm * 0.42), CGPoint(x: cx, y: y1 - arm * 0.42),
                       CGPoint(x: x0 + arm * 0.42, y: cy), CGPoint(x: x1 - arm * 0.42, y: cy)].enumerated() {
            let p = UIBezierPath()
            switch i {
            case 0: p.move(to: CGPoint(x: c.x, y: c.y - tri)); p.addLine(to: CGPoint(x: c.x - tri, y: c.y + tri * 0.6)); p.addLine(to: CGPoint(x: c.x + tri, y: c.y + tri * 0.6))
            case 1: p.move(to: CGPoint(x: c.x, y: c.y + tri)); p.addLine(to: CGPoint(x: c.x - tri, y: c.y - tri * 0.6)); p.addLine(to: CGPoint(x: c.x + tri, y: c.y - tri * 0.6))
            case 2: p.move(to: CGPoint(x: c.x - tri, y: c.y)); p.addLine(to: CGPoint(x: c.x + tri * 0.6, y: c.y - tri)); p.addLine(to: CGPoint(x: c.x + tri * 0.6, y: c.y + tri))
            default: p.move(to: CGPoint(x: c.x + tri, y: c.y)); p.addLine(to: CGPoint(x: c.x - tri * 0.6, y: c.y - tri)); p.addLine(to: CGPoint(x: c.x - tri * 0.6, y: c.y + tri))
            }
            p.close()
            p.fill()
        }
    }

    /// 어깨 버튼: 경첩 쪽 모서리에서 살짝 보이는 둥근 막대
    private func drawShoulder(_ ctx: CGContext, _ r: CGRect, _ label: String, pressed: Bool, left: Bool) {
        guard r.width > 0 else { return }
        let path = UIBezierPath(roundedRect: r, byRoundingCorners: left ? [.topLeft, .bottomRight, .bottomLeft] : [.topRight, .bottomLeft, .bottomRight],
                                cornerRadii: CGSize(width: r.height / 2, height: r.height / 2))
        convex(ctx, path, r, pressed: pressed, base: theme.button.mixed(with: theme.buttonShade, 0.25))
        Paint.text(label, at: CGPoint(x: r.midX, y: r.midY + (pressed ? 1.2 : 0)), size: r.height * 0.48, weight: .bold, color: theme.letter)
    }

    private func drawSmall(_ ctx: CGContext, _ r: CGRect, pressed: Bool) {
        guard r.width > 0 else { return }
        let path = UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)
        theme.faceShade.darker(theme.isLight ? 0.1 : 0.4).setFill()
        UIBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: r.height / 2 + 2).fill()
        convex(ctx, path, r, pressed: pressed)
    }
}
