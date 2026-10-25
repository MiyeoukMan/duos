import MetalKit
import UIKit

/// 펼친 DS 한 대: 몸(OpenBodyView) → 화면(Metal) → 카드 없음 화면 → 버튼 판(ControlsView) → 불빛.
final class OpenConsoleView: UIView {
    let body = OpenBodyView()
    let metalView = MTKView()
    let controls = ControlsView()
    let leds = LEDView()
    let noCard = NoCardView()
    private(set) var renderer: ScreenRenderer?
    private(set) var layout = Layout()

    var theme = ConsoleTheme.current {
        didSet { body.theme = theme; controls.theme = theme; noCard.setNeedsDisplay() }
    }
    /// 안전 영역(돌려 그릴 때는 컨트롤러가 대신 정해 준다 — 돌린 뷰의 safeAreaInsets는 믿을 수 없다)
    var safeInsets: UIEdgeInsets? { didSet { setNeedsLayout() } }
    var layoutStyle = Settings.shared.layoutStyle { didSet { if layoutStyle != oldValue { setNeedsLayout() } } }
    /// 반쯤 접힌 자세(경첩 띠를 조금 넓게)
    var bent = false { didSet { if bent != oldValue { setNeedsLayout() } } }
    var swapped = false { didSet { setNeedsLayout() } }
    /// 게임 화면을 보일지(아니면 "카드 없음" 화면)
    var showsGame = false {
        didSet {
            metalView.isHidden = !showsGame
            noCard.isHidden = showsGame
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(body)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.preferredFramesPerSecond = 60
        metalView.isUserInteractionEnabled = false
        metalView.isHidden = true
        addSubview(metalView)
        renderer = ScreenRenderer(view: metalView)
        addSubview(controls)
        addSubview(noCard)
        addSubview(leds)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        layout = Layout.make(bounds: b, safe: safeInsets ?? safeAreaInsets, bent: bent, style: layoutStyle)
        for v in [body, metalView, controls, noCard, leds] as [UIView] { v.frame = b }
        body.layout = layout
        controls.layout = layout
        controls.touchRect = showsGame ? (swapped ? layout.top : layout.bottom) : .zero
        renderer?.topRect = layout.top
        renderer?.bottomRect = layout.bottom
        renderer?.swapped = swapped
        noCard.layout = layout
        leds.place(power: layout.powerLED, charge: layout.chargeLED)
    }
}

/// 카드가 없을 때의 두 화면(DS 본체 메뉴 느낌): 위 = 날짜 · 시계, 아래 = 안내 + "여기서 고르기".
final class NoCardView: UIView {
    var layout = Layout() { didSet { setNeedsDisplay(); placeButton() } }
    /// 접을 수 있는 기기면 "접고 뒷면의 슬롯을", 아니면 아래 버튼을 안내
    var foldable = HingeMonitor.isFoldable { didSet { if foldable != oldValue { setNeedsDisplay() } } }
    let pickButton = UIButton(type: .system)
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        var cfg = UIButton.Configuration.filled()
        cfg.title = "여기서 카트리지 고르기"
        cfg.baseBackgroundColor = UIColor(hex: 0x3D8FE0)
        cfg.cornerStyle = .capsule
        cfg.buttonSize = .small
        pickButton.configuration = cfg
        addSubview(pickButton)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // 버튼 말고는 터치를 아래(버튼 판)로 흘린다
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    private func placeButton() {
        let b = layout.bottom
        pickButton.sizeToFit()
        pickButton.center = CGPoint(x: b.midX, y: b.maxY - b.height * 0.2)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), layout.top.width > 0 else { return }
        for (i, r) in [layout.top, layout.bottom].enumerated() {
            ctx.saveGState()
            UIBezierPath(rect: r).addClip()
            UIColor(hex: 0xF6F7F9).setFill()
            UIBezierPath(rect: r).fill()
            // 옅은 모눈(DS 메뉴 화면 느낌)
            let step = r.width / 16
            UIColor(hex: 0xDDE6F0).setFill()
            var x = r.minX
            while x < r.maxX { UIBezierPath(rect: CGRect(x: x, y: r.minY, width: 1, height: r.height)).fill(); x += step }
            var y = r.minY
            while y < r.maxY { UIBezierPath(rect: CGRect(x: r.minX, y: y, width: r.width, height: 1)).fill(); y += step }
            if i == 0 { drawClock(r) } else { drawMessage(r) }
            ctx.restoreGState()
        }
    }

    private func drawClock(_ r: CGRect) {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 EEEE"
        let date = f.string(from: now)
        f.dateFormat = "HH:mm"
        let time = f.string(from: now)
        let ink = UIColor(hex: 0x4C5560)
        Paint.text(time, at: CGPoint(x: r.midX, y: r.midY - r.height * 0.04), size: r.height * 0.3, weight: .bold, color: ink)
        Paint.text(date, at: CGPoint(x: r.midX, y: r.midY + r.height * 0.2), size: r.height * 0.075, weight: .semibold, color: ink.withAlphaComponent(0.8))
        // 위쪽 띠
        UIColor(hex: 0x3D8FE0).setFill()
        UIBezierPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.07)).fill()
    }

    private func drawMessage(_ r: CGRect) {
        let ink = UIColor(hex: 0x4C5560)
        Paint.text("카드가 꽂혀 있지 않습니다", at: CGPoint(x: r.midX, y: r.minY + r.height * 0.3), size: r.height * 0.075, weight: .bold, color: ink)
        let lines = foldable ? ["듀오를 접고 뒷면의 슬롯을 눌러", "카트리지를 넣으세요"] : ["아래 버튼을 눌러", "카트리지를 고르세요"]
        Paint.text(lines[0], at: CGPoint(x: r.midX, y: r.minY + r.height * 0.45), size: r.height * 0.055, weight: .medium, color: ink.withAlphaComponent(0.75))
        Paint.text(lines[1], at: CGPoint(x: r.midX, y: r.minY + r.height * 0.54), size: r.height * 0.055, weight: .medium, color: ink.withAlphaComponent(0.75))
    }
}
