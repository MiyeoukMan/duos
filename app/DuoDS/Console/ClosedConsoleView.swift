import UIKit

/// 접은 DS의 뒷면(가로). 위쪽 가장자리 = 경첩 쪽의 얇은 옆면 띠와 카드 슬롯만(경첩 · L/R · 불빛은 없앴다 — 10-26 "깔끔하게").
/// 판: 스티커(꽂힌 게임 · 안내를 천천히 깜빡이며) · 배터리 덮개 · 고무발 · 나사, 아래 가장자리에 슬롯-2 덮개.
/// 슬롯을 누르면 `onSlot`, 배터리 덮개를 누르면 `onCover`(설정). 카트리지 꽂기 · 빼기, 덮개 열기 · 닫기 애니메이션도 여기서.
final class ClosedConsoleView: UIView {
    var theme = ConsoleTheme.current { didSet { setNeedsDisplay(); cover.setNeedsDisplay() } }
    var onSlot: (() -> Void)?
    var onCover: (() -> Void)?
    /// 스티커에 띄우는 안내(첫 줄 = 게임 이름, 둘째 줄 = 안내. 한 줄이면 안내만) — 천천히 나타났다 사라지기를 되풀이
    var caption = "" { didSet { if caption != oldValue { showCaption() } } }

    /// 경첩이 없으니 접은 쪽엔 불빛도 없다(근거리 무선 등이 값을 넣어도 보이지 않게 숨겨 둔다)
    let leds = LEDView()
    private let message = UIView()
    private let messageTitle = UILabel()
    private let messageHint = UILabel()
    private let cover = BatteryCoverView()
    private let slotButton = UIControl()
    private let slotGlow = CAShapeLayer()
    /// 꽂힌 카드(위 끝만 슬롯 밖으로 보인다) — 슬롯 선(slot.midY)에서 아래를 잘라 내는 상자 안에(아래는 본체 속).
    /// 상자는 화면 위 바깥까지 이어져 있고 맨 앞에 둔다 — 덮개 · 스티커 등에 가리지 않게
    private let cardClip = UIView()
    private var insertedCard: CartridgeView?

    // 자리(layoutSubviews에서)
    private(set) var band = CGRect.zero
    private(set) var slot = CGRect.zero
    private var sticker = CGRect.zero
    private var battery = CGRect.zero
    private var feet: [CGPoint] = []
    private var screws: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        backgroundColor = .black
        cardClip.clipsToBounds = true
        cardClip.isUserInteractionEnabled = false
        slotButton.addAction(UIAction { [weak self] _ in self?.onSlot?() }, for: .touchUpInside)
        addSubview(slotButton)
        slotGlow.fillColor = UIColor.clear.cgColor
        slotGlow.lineWidth = 3
        layer.addSublayer(slotGlow)
        cover.owner = self
        cover.addAction(UIAction { [weak self] _ in self?.onCover?() }, for: .touchUpInside)
        addSubview(cover)
        message.isUserInteractionEnabled = false
        message.alpha = 0
        let ink = UIColor(hex: 0x5D6168)
        for l in [messageTitle, messageHint] {
            l.textColor = ink
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.55
            l.lineBreakMode = .byTruncatingTail
            message.addSubview(l)
        }
        addSubview(message)
        leds.isHidden = true
        addSubview(leds)
        addSubview(cardClip)
        NotificationCenter.default.addObserver(self, selector: #selector(restartBlink), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let W = bounds.width, H = bounds.height
        // 듀오는 앱이 화면 방향을 정할 수 없다(창 모드) — 든 방향대로 가로 · 세로 배치를 고른다. 경첩 쪽은 늘 위.
        if W >= H {
            let bh = max(H * 0.085, 44)
            band = CGRect(x: 0, y: 0, width: W, height: bh)
            slot = CGRect(x: W * 0.35, y: bh * 0.30, width: W * 0.30, height: bh * 0.42)
            sticker = CGRect(x: W * 0.07, y: H * 0.26, width: W * 0.32, height: H * 0.40)
            battery = CGRect(x: W * 0.47, y: H * 0.27, width: W * 0.44, height: H * 0.48)
            feet = [(0.055, 0.21), (0.945, 0.21), (0.055, 0.90), (0.945, 0.90)].map { CGPoint(x: W * $0.0, y: H * $0.1) }
            screws = [(0.43, 0.22), (0.43, 0.92), (0.96, 0.55)].map { CGPoint(x: W * $0.0, y: H * $0.1) }
        } else {
            let bh = max(H * 0.06, 44)
            band = CGRect(x: 0, y: 0, width: W, height: bh)
            slot = CGRect(x: W * 0.27, y: bh * 0.30, width: W * 0.46, height: bh * 0.42)
            sticker = CGRect(x: W * 0.08, y: H * 0.15, width: W * 0.62, height: H * 0.25)
            battery = CGRect(x: W * 0.12, y: H * 0.50, width: W * 0.76, height: H * 0.36)
            feet = [(0.07, 0.12), (0.93, 0.12), (0.07, 0.93), (0.93, 0.93)].map { CGPoint(x: W * $0.0, y: H * $0.1) }
            screws = [(0.84, 0.22), (0.50, 0.95), (0.50, 0.45)].map { CGPoint(x: W * $0.0, y: H * $0.1) }
        }

        slotButton.frame = slot.insetBy(dx: -24, dy: -26)
        let glow = UIBezierPath(roundedRect: slot.insetBy(dx: -4, dy: -4), cornerRadius: slot.height / 2 + 4)
        slotGlow.path = glow.cgPath
        slotGlow.frame = bounds
        cardClip.frame = CGRect(x: 0, y: slot.midY - H * 2, width: W, height: H * 2)
        if let card = insertedCard { card.frame = insertedFrame(for: card) }
        if cover.transform == .identity { cover.frame = battery }
        cover.setNeedsDisplay()
        leds.frame = bounds
        layoutMessage()
        updateGlow()
    }

    // ── 스티커 안내(꽂힌 게임 · 펼치면 시작) ──────────

    /// 스티커 안 글자 자리: 위 "DuoS"와 아래 모델 줄 · 바코드 사이
    private var messageRect: CGRect {
        let fs = stickerFont
        let top = sticker.minY + 8 + fs * 2.6
        let bottom = sticker.maxY - sticker.height * 0.30 - fs * 1.6
        return CGRect(x: sticker.minX + 12, y: top, width: sticker.width - 24, height: max(0, bottom - top))
    }

    private var stickerFont: CGFloat { min(sticker.height * 0.075, sticker.width * 0.05) }

    private func layoutMessage() {
        let r = messageRect
        message.frame = r
        let fs = stickerFont
        let two = !(messageTitle.text ?? "").isEmpty
        messageTitle.font = .systemFont(ofSize: fs * 1.75, weight: .heavy)
        messageHint.font = .systemFont(ofSize: fs * (two ? 1.3 : 1.45), weight: .semibold)
        let th = ceil(fs * 2.2), hh = ceil(fs * 1.8)
        let total = two ? th + 4 + hh : hh
        let y0 = (r.height - total) / 2
        messageTitle.frame = CGRect(x: 0, y: y0, width: r.width, height: th)
        messageHint.frame = CGRect(x: 0, y: two ? y0 + th + 4 : y0, width: r.width, height: hh)
        messageTitle.isHidden = !two
    }

    private func showCaption() {
        let parts = caption.split(separator: "\n", maxSplits: 1).map(String.init)
        messageTitle.text = parts.count > 1 ? parts[0] : ""
        messageHint.text = parts.last ?? ""
        layoutMessage()
        restartBlink()
    }

    /// 천천히 나타났다(0.5초) · 머물고(1.6초) · 사라지고(0.5초) · 잠깐 비었다가 되풀이. 동작 줄이기를 켜 두면 그냥 보인다
    @objc private func restartBlink() {
        message.layer.removeAnimation(forKey: "blink")
        guard !caption.isEmpty else { message.alpha = 0; return }
        message.alpha = 1
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0, 0]
        a.keyTimes = [0, 0.17, 0.70, 0.87, 1]
        a.duration = 3.0
        a.repeatCount = .infinity
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                             CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear)]
        message.layer.add(a, forKey: "blink")
    }

    // ── 슬롯 안내 빛(비어 있을 때 은은히) ──────────

    private func updateGlow() {
        slotGlow.strokeColor = UIColor(hex: 0x5AC8FA).cgColor
        slotGlow.removeAllAnimations()
        guard insertedCard == nil else { slotGlow.opacity = 0; return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.0
        a.toValue = 0.75
        a.duration = 1.2
        a.autoreverses = true
        a.repeatCount = .infinity
        slotGlow.add(a, forKey: "pulse")
    }

    // ── 카트리지 ─────────────────────────────

    var hasCard: Bool { insertedCard != nil }

    /// 꽂혔을 때 카드 자리(cardClip 좌표): 위 끝(손잡이)만 슬롯 위로 조금 나온다
    private func insertedFrame(for card: CartridgeView) -> CGRect {
        let w = slot.width - 8
        let h = w / CartridgeView.aspect
        let visible = h * 0.12
        return CGRect(x: slot.midX - w / 2, y: cardClip.bounds.height - visible, width: w, height: h)
    }

    /// 애니메이션 없이 꽂힌 상태로(앱을 다시 켰을 때)
    func showInserted(_ rom: RomEntry?) {
        insertedCard?.removeFromSuperview()
        insertedCard = nil
        if let rom {
            let card = CartridgeView(rom: rom)
            card.layer.shadowOpacity = 0
            cardClip.addSubview(card)
            insertedCard = card
            card.frame = insertedFrame(for: card)
        }
        updateGlow()
    }

    /// 고른 카드(이 뷰 좌표의 `from` 자리)를 실제 DS처럼 위에서 슬롯으로 꽂는다 — 라벨(앞면)이 보이게, 단자 쪽(아래 끝)부터.
    /// 슬롯이 화면 위 끝에 붙어 있어 그대로는 위쪽에 자리가 없다 → 본체를 잠깐 아래로 비켜 위쪽 바깥을 보이고, 꽂은 뒤 제자리로.
    func insert(_ rom: RomEntry, from: CGRect, completion: @escaping () -> Void) {
        insertedCard?.removeFromSuperview()
        insertedCard = nil
        slotGlow.opacity = 0
        slotGlow.removeAllAnimations()

        let w = slot.width - 8
        let h = w / CartridgeView.aspect
        let ready = CGRect(x: slot.midX - w / 2, y: slot.minY - 12 - h, width: w, height: h)
        let pan = max(0, 24 - ready.minY)
        let card = CartridgeView(rom: rom)
        card.frame = from
        addSubview(card)   // 맨 앞 — 날아가는 동안 덮개 · 스티커 위로
        let haptic = UIImpactFeedbackGenerator(style: .rigid)
        haptic.prepare()

        // 1) 본체는 아래로 비켜서고, 카드는 슬롯 바로 위로
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2) {
            self.transform = CGAffineTransform(translationX: 0, y: pan)
            card.frame = ready
        } completion: { _ in
            // 2) 자르는 상자로 옮겨 위에서 아래로 밀어 넣는다
            card.frame = self.convert(ready, to: self.cardClip)
            card.layer.shadowOpacity = 0
            self.cardClip.addSubview(card)
            self.insertedCard = card
            let final = self.insertedFrame(for: card)
            UIView.animate(withDuration: 0.30, delay: 0.06, options: [.curveEaseIn]) {
                card.frame = final.offsetBy(dx: 0, dy: 3)
            } completion: { _ in
                if Settings.shared.haptics { haptic.impactOccurred(intensity: 1) }
                // 딸깍 — 걸쇠가 살짝 밀어 올려 제자리
                UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                    card.frame = final
                } completion: { _ in
                    // 3) 본체가 제자리로
                    UIView.animate(withDuration: 0.42, delay: 0.1, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                        self.transform = .identity
                    } completion: { _ in completion() }
                }
            }
        }
    }

    /// 꽂힌 카드를 위로 빼내고 사라지게 한다.
    func eject(completion: @escaping () -> Void) {
        guard let card = insertedCard else { completion(); return }
        insertedCard = nil
        if Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        UIView.animate(withDuration: 0.30, delay: 0, options: [.curveEaseOut]) {
            card.frame = card.frame.offsetBy(dx: 0, dy: -card.frame.height * 0.6)
        } completion: { _ in
            card.removeFromSuperview()
            self.updateGlow()
            completion()
        }
    }

    // ── 배터리 덮개(= 설정) ──────────────────────

    /// 덮개를 아래(경첩 반대쪽)로 밀어 열어 배터리 칸을 보인다 / 다시 밀어 닫는다(딸깍)
    func openCover(_ open: Bool, completion: (() -> Void)? = nil) {
        let slide = battery.height * 0.24
        if open, Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        cover.lifted = open
        UIView.animate(withDuration: open ? 0.30 : 0.24, delay: 0, options: [open ? .curveEaseOut : .curveEaseIn]) {
            self.cover.transform = open ? CGAffineTransform(translationX: 0, y: slide).scaledBy(x: 1.012, y: 1.012) : .identity
        } completion: { _ in
            if !open, Settings.shared.haptics { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8) }
            completion?()
        }
    }

    // ── 그리기 ───────────────────────────────

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let t = theme
        let W = bounds.width, H = bounds.height
        let light = isLightShell

        // 판: 반짝이는 껍데기
        paintPlate(ctx, in: bounds)

        drawBand(ctx)

        // 고무발 · 나사
        for f in feet {
            let r = CGRect(x: f.x - 9, y: f.y - 6, width: 18, height: 12)
            Paint.shadow(ctx, UIColor(white: 0, alpha: 0.3), blur: 2, offset: CGSize(width: 0, height: 1)) {
                t.shellShade.mixed(with: .darkGray, 0.35).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 6).fill()
            }
        }
        for p in screws { drawScrew(p, r: 5) }

        // 배터리 칸(덮개를 밀면 보인다): 움푹한 칸 + 배터리 팩 + 단자
        let bay = UIBezierPath(roundedRect: battery, cornerRadius: 10)
        Paint.linear(ctx, bay, [t.shellShade.darker(light ? 0.55 : 0.75), t.shellShade.darker(light ? 0.35 : 0.6)],
                     from: CGPoint(x: 0, y: battery.minY), to: CGPoint(x: 0, y: battery.maxY))
        let pack = battery.insetBy(dx: battery.width * 0.09, dy: battery.height * 0.14)
        let packPath = UIBezierPath(roundedRect: pack, cornerRadius: 6)
        Paint.linear(ctx, packPath, [UIColor(white: 0.30, alpha: 1), UIColor(white: 0.17, alpha: 1)],
                     from: CGPoint(x: 0, y: pack.minY), to: CGPoint(x: 0, y: pack.maxY))
        UIColor(white: 1, alpha: 0.12).setStroke()
        packPath.lineWidth = 1
        packPath.stroke()
        Paint.text("Li-ion  3.7V", at: CGPoint(x: pack.midX, y: pack.midY), size: max(9, pack.height * 0.12), weight: .bold, color: UIColor(white: 0.62, alpha: 1))
        for i in 0..<3 {
            let x = pack.minX + pack.width * (0.30 + CGFloat(i) * 0.2) - 4
            UIColor(hex: 0xC9A74A).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: battery.minY + battery.height * 0.05, width: 8, height: battery.height * 0.07), cornerRadius: 1.5).fill()
        }

        // 스티커
        let st = UIBezierPath(roundedRect: sticker, cornerRadius: 6)
        Paint.linear(ctx, st, [UIColor(hex: 0xE8E9EB), UIColor(hex: 0xC8CBD0)], from: CGPoint(x: sticker.minX, y: sticker.minY), to: CGPoint(x: sticker.maxX, y: sticker.maxY))
        UIColor(white: 0, alpha: 0.12).setStroke()
        st.lineWidth = 1
        st.stroke()
        let ink = UIColor(hex: 0x5D6168)
        let fs = stickerFont
        Paint.text("DuoS", at: CGPoint(x: sticker.minX + 12, y: sticker.minY + 8), size: fs * 1.9, weight: .heavy, color: ink, rounded: false, center: false)
        // 가운데는 꽂힌 게임 · 안내(message 뷰가 깜빡이며) — 아래에 모델 줄
        Paint.text("MODEL NO. DUO-001   SERIAL D\(Int(W) % 97)\(Int(H) % 89)-0527", at: CGPoint(x: sticker.minX + 12, y: sticker.maxY - sticker.height * 0.30 - fs * 1.45),
                   size: fs * 0.8, weight: .medium, color: ink.withAlphaComponent(0.8), rounded: false, center: false)
        // 바코드
        var bx = sticker.minX + 12
        var seed: UInt32 = 0x5EED
        while bx < sticker.maxX - 12 {
            seed = seed &* 1664525 &+ 1013904223
            let bw = CGFloat(1 + (seed >> 28) % 3)
            if (seed >> 20) & 1 == 0 { ink.setFill(); UIBezierPath(rect: CGRect(x: bx, y: sticker.maxY - sticker.height * 0.26, width: bw, height: sticker.height * 0.18)).fill() }
            bx += bw + 1
        }

        // 아래 가장자리: 슬롯-2 덮개
        let s2 = CGRect(x: W * 0.30, y: H - 9, width: W * 0.40, height: 9)
        t.shellShade.darker(light ? 0.35 : 0.6).setFill()
        UIBezierPath(roundedRect: s2, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4)).fill()
    }

    /// 판 바탕(껍데기 그라데이션 + 비스듬한 빛) — `area`만 칠한다. 덮개도 제 자리에 같은 판을 칠해 이어 보이게 한다
    func paintPlate(_ ctx: CGContext, in area: CGRect) {
        let t = theme
        let W = bounds.width, H = bounds.height
        ctx.saveGState()
        ctx.clip(to: area)
        Paint.linear(ctx, UIBezierPath(rect: bounds), [t.shell.lighter(0.18), t.shell, t.shell.mixed(with: t.shellShade, 0.6)],
                     from: CGPoint(x: 0, y: band.maxY), to: CGPoint(x: 0, y: H))
        let sheen = UIBezierPath()
        sheen.move(to: CGPoint(x: W * 0.18, y: band.maxY))
        sheen.addLine(to: CGPoint(x: W * 0.42, y: band.maxY))
        sheen.addLine(to: CGPoint(x: W * 0.26, y: H))
        sheen.addLine(to: CGPoint(x: W * 0.02, y: H))
        sheen.close()
        UIColor(white: 1, alpha: isLightShell ? 0.20 : 0.07).setFill()
        sheen.fill()
        ctx.restoreGState()
    }

    var isLightShell: Bool {
        var w: CGFloat = 0
        theme.shell.getWhite(&w, alpha: nil)
        return w > 0.55
    }

    func drawScrew(_ c: CGPoint, r: CGFloat) {
        let t = theme
        t.shellShade.darker(0.25).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        UIColor(white: 0.75, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r * 0.7, y: c.y - r * 0.7, width: r * 1.4, height: r * 1.4)).fill()
        UIColor(white: 0.35, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: c.x - r * 0.5, y: c.y - 0.6, width: r, height: 1.2)).fill()
        UIBezierPath(rect: CGRect(x: c.x - 0.6, y: c.y - r * 0.5, width: 1.2, height: r)).fill()
    }

    /// 위쪽 가장자리(경첩 쪽 옆면) — 얇은 띠 하나에 카드 슬롯
    private func drawBand(_ ctx: CGContext) {
        let t = theme
        let light = isLightShell
        let b = band
        Paint.linear(ctx, UIBezierPath(rect: b), [t.shellShade.darker(0.12), t.shellShade.mixed(with: t.shell, 0.35)],
                     from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
        // 판과 만나는 모서리 빛
        UIColor(white: 1, alpha: light ? 0.7 : 0.18).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: b.maxY - 1, width: b.width, height: 1)).fill()

        // 카드 슬롯(어두운 틈 + 아랫입술 빛)
        let sp = UIBezierPath(roundedRect: slot, cornerRadius: slot.height / 2)
        Paint.linear(ctx, sp, [UIColor(white: 0.02, alpha: 1), UIColor(white: 0.16, alpha: 1)], from: CGPoint(x: 0, y: slot.minY), to: CGPoint(x: 0, y: slot.maxY))
        UIColor(white: 1, alpha: light ? 0.55 : 0.15).setStroke()
        let lip = UIBezierPath()
        lip.move(to: CGPoint(x: slot.minX + slot.height / 2, y: slot.maxY + 1))
        lip.addLine(to: CGPoint(x: slot.maxX - slot.height / 2, y: slot.maxY + 1))
        lip.lineWidth = 1
        lip.stroke()
        Paint.text("▲ CARTRIDGE", at: CGPoint(x: slot.midX, y: b.maxY + 12), size: max(8, min(b.height * 0.24, 12)), weight: .heavy,
                   color: t.shellShade.darker(isLightShell ? 0.25 : 0.0), kern: 0.8)
    }
}

/// 배터리 덮개 — 누르면 설정. 판과 같은 껍데기를 제 자리에 칠하고(이어 보이게) 이음매 · 나사 · 미끄럼 홈 · 새긴 글을 얹는다.
/// 누르는 동안 살짝 눌려 보이고, 열리면(`lifted`) 그림자가 생긴다.
final class BatteryCoverView: UIControl {
    weak var owner: ClosedConsoleView?
    var lifted = false {
        didSet {
            layer.shadowOpacity = lifted ? 0.35 : 0
            layer.shadowRadius = lifted ? 6 : 0
            layer.shadowOffset = CGSize(width: 0, height: lifted ? 3 : 0)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : 1 }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let owner else { return }
        let t = owner.theme
        let light = owner.isLightShell
        let b = bounds
        let shape = UIBezierPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 10)

        // 판과 같은 껍데기(덮개가 닫혀 있을 땐 판의 그 자리와 똑같이 보인다)
        // 닫힌 자리(변형과 상관없는 center로) — 덮개 무늬는 덮개와 함께 움직인다
        let closed = CGRect(x: center.x - b.width / 2, y: center.y - b.height / 2, width: b.width, height: b.height)
        ctx.saveGState()
        shape.addClip()
        ctx.translateBy(x: -closed.minX, y: -closed.minY)
        owner.paintPlate(ctx, in: closed)
        ctx.restoreGState()

        // 이음매(어두운 선 + 아래 빛)
        t.shellShade.darker(light ? 0.15 : 0.4).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
        UIColor(white: 1, alpha: light ? 0.6 : 0.12).setStroke()
        let lip = UIBezierPath(roundedRect: b.insetBy(dx: 1.5, dy: 1.5).offsetBy(dx: 0, dy: 1), cornerRadius: 9)
        lip.lineWidth = 1
        lip.stroke()

        owner.drawScrew(CGPoint(x: b.minX + 18, y: b.minY + 18), r: 6)
        // 미끄럼 홈(아래로 밀어 연다)
        let groove = t.shellShade.darker(light ? 0.1 : 0.35)
        for i in 0..<5 {
            let y = b.maxY - 18 - CGFloat(i) * 6
            groove.setFill()
            UIBezierPath(roundedRect: CGRect(x: b.midX - 22, y: y, width: 44, height: 2), cornerRadius: 1).fill()
        }
        // 새긴 글
        let ink = t.shellShade.darker(light ? 0.25 : 0.0)
        let size = max(8, min(b.width, b.height) * 0.042)
        Paint.text("▼ SETTINGS", at: CGPoint(x: b.midX, y: b.maxY - 18 - 4 * 6 - size * 1.3),
                   size: size, weight: .heavy, color: ink, kern: 0.8)
    }
}
