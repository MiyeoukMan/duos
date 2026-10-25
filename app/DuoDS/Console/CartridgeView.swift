import UIKit

/// DS 게임 카드 한 장(앞면). 비율 35 : 33(가로 : 세로), 짙은 회색 껍데기, 위쪽 손잡이 홈, 오른쪽 위 모서리 깎임,
/// 라벨 = ROM 배너 아이콘(픽셀 그대로 크게) + 그 아이콘의 대표 색 바탕 + 제목.
/// `rom`이 없으면 "가져오기" 카드(빈 라벨에 +).
final class CartridgeView: UIView {
    static let aspect: CGFloat = 35.0 / 33.0

    let rom: RomEntry?
    /// 뒷면(금색 단자 · 손잡이가 아래) — 슬롯에 꽂을 때 뒤집어 보인다
    let back: Bool
    private let icon: UIImage?
    private let labelColor: UIColor

    init(rom: RomEntry?, back: Bool = false) {
        self.rom = rom
        self.back = back
        icon = rom.flatMap { Library.shared.icon(for: $0) }
        labelColor = icon.flatMap { CartridgeView.dominantColor($0) } ?? UIColor(hex: rom == nil ? 0x8E9399 : 0x4A6FD0)
        super.init(frame: CGRect(x: 0, y: 0, width: 140, height: 140 / CartridgeView.aspect))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 손잡이 띠의 높이(꽂았을 때 슬롯 밖으로 남는 부분)
    var gripHeight: CGFloat { bounds.height * 0.17 }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if back { drawBack(ctx); return }
        let b = bounds.insetBy(dx: 1, dy: 1)
        let w = b.width, h = b.height
        let cut = w * 0.09
        let r = w * 0.05

        // 껍데기(오른쪽 위 모서리를 비스듬히 깎음)
        let shell = UIBezierPath()
        shell.move(to: CGPoint(x: b.minX + r, y: b.minY))
        shell.addLine(to: CGPoint(x: b.maxX - cut, y: b.minY))
        shell.addLine(to: CGPoint(x: b.maxX, y: b.minY + cut))
        shell.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
        shell.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.maxY), controlPoint: CGPoint(x: b.maxX, y: b.maxY))
        shell.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
        shell.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY - r), controlPoint: CGPoint(x: b.minX, y: b.maxY))
        shell.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        shell.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.minY), controlPoint: CGPoint(x: b.minX, y: b.minY))
        shell.close()
        Paint.linear(ctx, shell, [UIColor(hex: 0x55575D), UIColor(hex: 0x3A3B40), UIColor(hex: 0x2C2D31)],
                     from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
        UIColor(white: 1, alpha: 0.12).setStroke()
        shell.lineWidth = 1
        shell.stroke()

        // 손잡이 홈
        let grip = h * 0.17
        for i in 0..<4 {
            let y = b.minY + grip * (0.25 + CGFloat(i) * 0.18)
            UIColor(white: 0, alpha: 0.35).setFill()
            UIBezierPath(rect: CGRect(x: b.minX + w * 0.12, y: y, width: w * 0.62, height: 1)).fill()
            UIColor(white: 1, alpha: 0.10).setFill()
            UIBezierPath(rect: CGRect(x: b.minX + w * 0.12, y: y + 1, width: w * 0.62, height: 0.8)).fill()
        }
        Paint.text("DuoS", at: CGPoint(x: b.maxX - w * 0.17, y: b.minY + grip * 0.55), size: max(6, w * 0.055), weight: .heavy,
                   color: UIColor(white: 1, alpha: 0.35), rounded: false, kern: 0.3)

        // 라벨
        let label = CGRect(x: b.minX + w * 0.07, y: b.minY + grip + h * 0.02, width: w * 0.86, height: h - grip - h * 0.1)
        let lp = UIBezierPath(roundedRect: label, cornerRadius: w * 0.025)
        if rom == nil {
            Paint.linear(ctx, lp, [UIColor(hex: 0xE9EAEC), UIColor(hex: 0xC9CCD0)], from: CGPoint(x: 0, y: label.minY), to: CGPoint(x: 0, y: label.maxY))
            Paint.text("+", at: CGPoint(x: label.midX, y: label.midY - label.height * 0.08), size: label.height * 0.42, weight: .light, color: UIColor(hex: 0x7A7F86))
            Paint.text("가져오기", at: CGPoint(x: label.midX, y: label.maxY - label.height * 0.16), size: max(8, w * 0.085), weight: .bold, color: UIColor(hex: 0x6A6F76))
            return
        }
        Paint.linear(ctx, lp, [labelColor.lighter(0.35), labelColor, labelColor.darker(0.35)], from: CGPoint(x: label.minX, y: label.minY), to: CGPoint(x: label.maxX, y: label.maxY))
        // 라벨 위 흰 띠(카드 라벨의 상단 띠 느낌)
        let band = CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height * 0.13)
        ctx.saveGState()
        lp.addClip()
        UIColor(white: 1, alpha: 0.88).setFill()
        UIBezierPath(rect: band).fill()
        ctx.restoreGState()
        if let code = rom?.gameCode, !code.isEmpty {
            Paint.text(code, at: CGPoint(x: band.midX, y: band.midY), size: band.height * 0.62, weight: .heavy, color: labelColor.darker(0.45), rounded: false, kern: 1)
        }

        // 아이콘(픽셀 그대로)
        let iconSize = min(label.width * 0.52, label.height * 0.5)
        let iconRect = CGRect(x: label.midX - iconSize / 2, y: band.maxY + label.height * 0.06, width: iconSize, height: iconSize)
        if let cg = icon?.cgImage {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: iconRect.maxY + iconRect.minY)
            ctx.scaleBy(x: 1, y: -1)
            Paint.shadow(ctx, UIColor(white: 0, alpha: 0.4), blur: 3, offset: CGSize(width: 0, height: -1.5)) {
                ctx.draw(cg, in: iconRect)
            }
            ctx.restoreGState()
        } else {
            let initial = String((rom?.title ?? "?").prefix(1)).uppercased()
            Paint.text(initial, at: CGPoint(x: iconRect.midX, y: iconRect.midY), size: iconSize * 0.7, weight: .black, color: UIColor(white: 1, alpha: 0.85))
        }

        // 제목(두 줄까지)
        let title = rom?.title ?? ""
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let fs = max(7, w * 0.075)
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fs, weight: .heavy), .foregroundColor: UIColor.white, .paragraphStyle: para,
            .shadow: { let s = NSShadow(); s.shadowColor = UIColor(white: 0, alpha: 0.5); s.shadowOffset = CGSize(width: 0, height: 1); s.shadowBlurRadius = 2; return s }(),
        ]
        let textRect = CGRect(x: label.minX + 4, y: iconRect.maxY + label.height * 0.03, width: label.width - 8, height: label.maxY - iconRect.maxY - label.height * 0.05)
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attr, context: nil)
    }

    /// 뒷면: 앞면을 아래위로 뒤집은 모양(깎인 모서리가 오른쪽 아래, 손잡이가 아래), 위쪽에 금색 단자
    private func drawBack(_ ctx: CGContext) {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let w = b.width, h = b.height
        let cut = w * 0.09
        let r = w * 0.05
        let shell = UIBezierPath()
        shell.move(to: CGPoint(x: b.minX + r, y: b.minY))
        shell.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        shell.addQuadCurve(to: CGPoint(x: b.maxX, y: b.minY + r), controlPoint: CGPoint(x: b.maxX, y: b.minY))
        shell.addLine(to: CGPoint(x: b.maxX, y: b.maxY - cut))
        shell.addLine(to: CGPoint(x: b.maxX - cut, y: b.maxY))
        shell.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
        shell.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY - r), controlPoint: CGPoint(x: b.minX, y: b.maxY))
        shell.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        shell.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.minY), controlPoint: CGPoint(x: b.minX, y: b.minY))
        shell.close()
        Paint.linear(ctx, shell, [UIColor(hex: 0x4E5056), UIColor(hex: 0x37383D), UIColor(hex: 0x2A2B2F)],
                     from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
        UIColor(white: 1, alpha: 0.12).setStroke()
        shell.lineWidth = 1
        shell.stroke()
        // 금색 단자
        let n = 17
        let padW = w * 0.62 / CGFloat(n)
        let x0 = b.midX - padW * CGFloat(n) / 2
        UIColor(white: 0, alpha: 0.4).setFill()
        UIBezierPath(roundedRect: CGRect(x: x0 - 3, y: b.minY + h * 0.035, width: padW * CGFloat(n) + 6, height: h * 0.15), cornerRadius: 2).fill()
        for i in 0..<n {
            let pad = CGRect(x: x0 + CGFloat(i) * padW + padW * 0.18, y: b.minY + h * 0.05, width: padW * 0.64, height: h * 0.12)
            Paint.linear(ctx, UIBezierPath(rect: pad), [UIColor(hex: 0xF6D77A), UIColor(hex: 0xC99A2E)], from: CGPoint(x: 0, y: pad.minY), to: CGPoint(x: 0, y: pad.maxY))
        }
        // 가운데 새김 글씨 · 아래 손잡이 홈
        Paint.text("DuoS", at: CGPoint(x: b.midX, y: b.midY), size: max(7, w * 0.08), weight: .heavy, color: UIColor(white: 1, alpha: 0.18), rounded: false, kern: 0.5)
        let grip = h * 0.17
        for i in 0..<4 {
            let y = b.maxY - grip * (0.25 + CGFloat(i) * 0.18)
            UIColor(white: 0, alpha: 0.35).setFill()
            UIBezierPath(rect: CGRect(x: b.minX + w * 0.12, y: y, width: w * 0.62, height: 1)).fill()
            UIColor(white: 1, alpha: 0.10).setFill()
            UIBezierPath(rect: CGRect(x: b.minX + w * 0.12, y: y + 1, width: w * 0.62, height: 0.8)).fill()
        }
    }

    /// 아이콘의 대표 색(투명하지 않은 픽셀 평균을 조금 진하게)
    static func dominantColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); count += 1
        }
        guard count > 0 else { return nil }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        UIColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        return UIColor(hue: hue, saturation: min(1, sat * 1.3 + 0.15), brightness: min(0.8, max(0.35, bri)), alpha: 1)
    }
}
