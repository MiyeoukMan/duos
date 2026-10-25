import UIKit

/// 펼친 DS(세로) 자리 계산 — 포인트, 화면(뷰) 좌표. 접힌 선(듀오의 주름) = 화면 한가운데 = DS 경첩.
///
/// - 실기기 비율(기본): DS Lite 치수(mm)를 듀오 폭에 맞춰 그대로 줄인다 — 위 · 아래 화면이 같은 크기, START/SELECT는 ABXY 밑에 세로로.
/// - 화면 크게: 위 화면을 판 가득, 아래는 터치 화면 · 십자키 · ABXY, 작은 버튼은 가로 줄.
/// L/R은 둘 다 아래 판의 경첩 쪽 모서리(진짜 DS의 어깨 자리).
struct Layout {
    var top = CGRect.zero
    var bottom = CGRect.zero
    var dpad = CGRect.zero
    var face = CGRect.zero        // A B X Y 넷을 담는 정사각형
    var l = CGRect.zero
    var r = CGRect.zero
    var start = CGRect.zero
    var select = CGRect.zero
    var settings = CGRect.zero
    var mic = CGRect.zero
    /// 경첩(주름 띠)
    var hinge = CGRect.zero
    var speakerLeft = CGPoint.zero
    var speakerRight = CGPoint.zero
    /// 경첩의 전원 · 충전 불빛, 마이크 구멍
    var powerLED = CGPoint.zero
    var chargeLED = CGPoint.zero
    var micHole = CGPoint.zero
    /// 위 판 / 아래 판 전체
    var lid = CGRect.zero
    var base = CGRect.zero
    var speakerRadius: CGFloat = 22
    /// FPS 글씨 자리(경첩 왼쪽 마디)
    var fpsSpot = CGRect.zero
    /// 작은 버튼 글씨를 버튼 옆 바깥쪽에(실기기 비율 — 화면 쪽은 좁다). 아니면 버튼 밑
    var labelsBeside = false

    static let aspect: CGFloat = 4.0 / 3.0

    static func make(bounds b: CGRect, safe: UIEdgeInsets, bent: Bool, style: Settings.LayoutStyle = .real) -> Layout {
        style == .real ? real(bounds: b, safe: safe, bent: bent) : large(bounds: b, safe: safe, bent: bent)
    }

    /// 경첩 · 뚜껑 · 바닥 판(두 배치 공통)
    private static func frame(_ b: CGRect, bent: Bool) -> Layout {
        var L = Layout()
        let fold = b.midY
        let hingeH: CGFloat = bent ? 30 : 24
        L.hinge = CGRect(x: 0, y: fold - hingeH / 2, width: b.width, height: hingeH)
        L.lid = CGRect(x: 0, y: 0, width: b.width, height: L.hinge.minY)
        L.base = CGRect(x: 0, y: L.hinge.maxY, width: b.width, height: b.maxY - L.hinge.maxY)
        L.micHole = CGPoint(x: b.midX, y: L.hinge.midY)
        L.powerLED = CGPoint(x: b.width * 0.80, y: L.hinge.midY)
        L.chargeLED = CGPoint(x: b.width * 0.80 + 16, y: L.hinge.midY)
        // 경첩 원통의 왼쪽 마디(가장자리 ~ 가운데 마디 홈) 가운데
        let segLeft = b.midX - b.width * 0.18
        L.fpsSpot = CGRect(x: 6, y: L.hinge.minY, width: segLeft - 6, height: L.hinge.height)
        return L
    }

    /// DS Lite 실측(mm): 본체 폭 133 · 판 높이 74 · 화면 62 × 46.5. 바닥 판(경첩에서): 화면 위 9.5, 십자키 · ABXY 가운데 27(바깥 끝에서 19.5),
    /// START 47 · SELECT 54(오른 끝에서 22). 듀오 판이 DS보다 세로로 길어서 남는 높이는 뚜껑 · 바닥 모두 위아래로 반씩 나눈다.
    /// 사용자 조정(위 화면 배율 · 바닥 묶음 내림 · 버튼 벌림)은 함수 맨 위 값들.
    private static func real(bounds b: CGRect, safe: UIEdgeInsets, bent: Bool) -> Layout {
        // 사용자 조정값(2026-10-25 — "위 화면 진짜 조금만 더 · 아래 묶음 아주 살짝 아래로 · 버튼을 화면 바깥쪽으로 아주 약간, 너무 몰려 있어 불편")
        let topScale: CGFloat = 1.30          // 위 화면 배율(실기 = 1)
        let baseDrop: CGFloat = 0.5           // 남는 높이 중 바닥 묶음을 내리는 몫
        let baseNudge: CGFloat = 15           // 그 위에 더 내리는 pt(L/R 포함)
        let spread: CGFloat = 1.5             // 십자키 · ABXY · 작은 버튼을 바깥으로 벌리는 mm

        var L = frame(b, bent: bent)
        L.labelsBeside = true
        let x0 = safe.left
        let W = b.width - safe.left - safe.right
        let mm = W / 133
        let screen = CGSize(width: (62 * mm).rounded(), height: (46.5 * mm).rounded())
        let topScreen = CGSize(width: (screen.width * topScale).rounded(), height: (screen.height * topScale).rounded())

        // 뚜껑: 위 화면을 판 가운데, 스피커는 화면 옆 빈자리의 가운데(화면과 같은 높이)
        let lidTop = max(safe.top, 0)
        L.top = CGRect(x: (x0 + (W - topScreen.width) / 2).rounded(), y: (lidTop + (L.hinge.minY - lidTop - topScreen.height) / 2).rounded(),
                       width: topScreen.width, height: topScreen.height)
        let bezel: CGFloat = 13   // 화면 테(10 + 파인 자리 3)
        L.speakerRadius = min(3.6 * mm, (L.top.minX - bezel - x0) / 2 - 6)
        L.speakerLeft = CGPoint(x: (x0 + L.top.minX - bezel) / 2, y: L.top.midY)
        L.speakerRight = CGPoint(x: (L.top.maxX + bezel + x0 + W) / 2, y: L.top.midY)

        // 바닥 판: 경첩에서 잰 실기 자리 + 남는 높이의 몫 + 조금 더
        let baseBottom = b.maxY - max(safe.bottom, 8)
        let spare = max(0, baseBottom - L.hinge.maxY - 74 * mm)
        let y0 = (L.hinge.maxY + spare * baseDrop + baseNudge).rounded()
        L.bottom = CGRect(x: (x0 + (W - screen.width) / 2).rounded(), y: (y0 + 9.5 * mm).rounded(), width: screen.width, height: screen.height)
        // L/R: 어깨 자리(경첩 쪽 모서리)에서 같이 조금 내림
        L.l = CGRect(x: x0 + 3 * mm, y: L.hinge.maxY + 1.5 * mm + baseNudge, width: 24 * mm, height: 7 * mm)
        L.r = CGRect(x: x0 + W - 27 * mm, y: L.hinge.maxY + 1.5 * mm + baseNudge, width: 24 * mm, height: 7 * mm)
        let pad = 19.5 * mm, face = 23 * mm, cy = y0 + 27 * mm
        let side = (19.5 - spread) * mm
        L.dpad = CGRect(x: x0 + side - pad / 2, y: cy - pad / 2, width: pad, height: pad)
        L.face = CGRect(x: x0 + W - side - face / 2, y: cy - face / 2, width: face, height: face)
        let small = CGSize(width: 7.5 * mm, height: 4.6 * mm)
        func pill(_ cx: CGFloat, _ cyMM: CGFloat) -> CGRect {
            CGRect(x: cx - small.width / 2, y: y0 + cyMM * mm - small.height / 2, width: small.width, height: small.height)
        }
        // 버튼 옆 바깥쪽 인쇄 글씨(가장 긴 SETTINGS)가 판 밖으로 잘리지 않게 — 좁은 아이폰에선 버튼을 조금 안쪽으로(듀오는 그대로)
        let labelW = ("SETTINGS" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .kern: 0.8]).width
        let smallSide = max((22 - spread) * mm, 6 + labelW + 7 + small.width / 2)
        L.start = pill(x0 + W - smallSide, 47)
        L.select = pill(x0 + W - smallSide, 54)
        L.settings = pill(x0 + smallSide, 47)
        L.mic = pill(x0 + smallSide, 54)
        return L
    }

    private static func large(bounds b: CGRect, safe: UIEdgeInsets, bent: Bool) -> Layout {
        var L = frame(b, bent: bent)

        let W = b.width - safe.left - safe.right
        let x0 = safe.left

        // 위 판: 스피커 몫을 남기고 4:3으로 최대한 크게, 경첩 쪽으로 붙인다
        let speakerCol = max(W * 0.095, 52)
        let lidTop = max(safe.top, 10) + 10
        let lidArea = CGRect(x: x0 + speakerCol, y: lidTop, width: W - speakerCol * 2, height: L.hinge.minY - 16 - lidTop)
        L.top = fit(lidArea)
        L.top.origin.y = L.hinge.minY - 16 - L.top.height
        L.speakerLeft = CGPoint(x: x0 + (L.top.minX - x0) / 2, y: L.top.midY)
        L.speakerRight = CGPoint(x: L.top.maxX + (x0 + W - L.top.maxX) / 2, y: L.top.midY)

        // 아래 판
        let lowerTop = L.hinge.maxY
        let lowerBottom = b.maxY - max(safe.bottom, 8)
        let lowerH = lowerBottom - lowerTop
        let col = min(max(W * 0.22, 120), 170)

        // L / R: 경첩 쪽 모서리
        let shoulderH: CGFloat = 36
        L.l = CGRect(x: x0 + 10, y: lowerTop + 8, width: col - 22, height: shoulderH)
        L.r = CGRect(x: x0 + W - col + 12, y: lowerTop + 8, width: col - 22, height: shoulderH)

        // 터치 화면: 가운데, 경첩 쪽으로
        L.bottom = fit(CGRect(x: x0 + col, y: lowerTop + 16, width: W - col * 2, height: lowerH * 0.72), alignTop: true)

        // 십자키 · ABXY: 터치 화면 가운데 높이(2026-10-25 사용자: "너무 아래에 있어서 불편해 조금 위로") — 어깨보다는 아래
        let inner = col - 13            // 터치 화면 테(10 + 3)를 뺀 기둥 폭
        let size = min(inner - 16, 146)
        let small = CGSize(width: min(inner / 2 - 9, 56), height: 22)
        let rowGap: CGFloat = 18
        let bandTop = L.l.maxY + 12
        let centerY = max(L.bottom.midY - 6, bandTop + size / 2)
        L.dpad = CGRect(x: x0 + inner / 2 - size / 2 + 2, y: centerY - size / 2, width: size, height: size)
        L.face = CGRect(x: x0 + W - inner / 2 - size / 2 - 2, y: centerY - size / 2, width: size, height: size)

        // 작은 버튼 줄: 십자키 · ABXY 바로 밑(글씨는 버튼 밑에 인쇄). 터치 화면 테를 넘지 않게 기둥 안쪽에서 가운데
        let rowY = min(L.face.maxY + rowGap, lowerBottom - small.height - 18)
        let leftMid = x0 + inner / 2 + 2, rightMid = x0 + W - inner / 2 - 2
        L.select = CGRect(x: rightMid - small.width - 5, y: rowY, width: small.width, height: small.height)
        L.start = CGRect(x: rightMid + 5, y: rowY, width: small.width, height: small.height)
        L.settings = CGRect(x: leftMid - small.width - 5, y: rowY, width: small.width, height: small.height)
        L.mic = CGRect(x: leftMid + 5, y: rowY, width: small.width, height: small.height)
        return L
    }

    private static func fit(_ area: CGRect, alignTop: Bool = false) -> CGRect {
        var w = area.width
        var h = w / aspect
        if h > area.height { h = area.height; w = h * aspect }
        let x = area.midX - w / 2
        let y = alignTop ? area.minY : area.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h).integral
    }
}
