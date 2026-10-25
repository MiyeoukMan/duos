// gfxshot — 앱과 같은 그래픽 단계(app/DuoDS/Render/ScreenPipeline.swift)를 맥에서 돌려 확대 방식 · 효과를 비교한다.
//   swiftc -O tools/gfxshot/main.swift app/DuoDS/Render/ScreenPipeline.swift -o build/macos/gfxshot
//   build/macos/gfxshot 입력.png 출력폴더 [너비x높이] [잘라낼곳 x,y,w,h(출력 좌표)]
// 입력은 256×192(또는 dsrun의 256×384 — 위 화면만). 방식마다 출력폴더/이름.png, 잘라낼 곳을 주면 비교판 sheet.png도.
//
//   build/macos/gfxshot --hires 출력.png 너비x높이 x,y,w,h 1배.png 이름=고해상도.png …
// 3D 내부 해상도 비교판: 1배 그림(dsrun 기본)을 지금 확대 방식(선명하게 · MetalFX)으로, 고해상도 그림(dsrun --scale N)은
// 앱처럼 확대 단계 없이 마지막 패스로 — 같은 크기로 그려 같은 곳을 잘라 나란히 + 전체 축소판.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

func loadBGRA(_ path: String) -> [UInt8] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("못 읽음: \(path)") }
    let w = 256, h = 192
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .none
    // 위 화면(위쪽 192줄)만 — CG 좌표는 아래가 0
    ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))
    return buf
}

func savePNG(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

func image(_ tex: MTLTexture) -> CGImage {
    let w = tex.width, h = tex.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&buf, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    return ctx.makeImage()!
}

// dsrun PNG의 위 화면(위쪽 절반)을 원래 크기로 — 256 × 384면 256 × 192, 1024 × 1536이면 1024 × 768
func loadTop(_ path: String) -> (pixels: [UInt8], width: Int, height: Int) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("못 읽음: \(path)") }
    let w = img.width, h = img.height * 3 / 4 >= img.width ? img.height / 2 : img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))
    return (buf, w, h)
}

// 같은 곳을 잘라 1:1로 나란히(위) + 전체를 줄여 나란히(아래), 이름은 각 칸 아래
func sheet(_ results: [(String, CGImage)], crop: CGRect, full: CGSize, cols: Int) -> CGImage {
    let pad = 12, labelH = 34
    let cw = Int(crop.width), ch = Int(crop.height)
    let k = CGFloat(cw) / full.width
    let fw = cw, fh = Int(full.height * k)
    let rows = (results.count + cols - 1) / cols
    let blockH = ch + labelH + pad + fh + labelH
    let sw = cols * cw + (cols + 1) * pad, sh = rows * blockH + (rows + 1) * pad
    let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: sw, height: sh))
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    func label(_ text: String, _ x: Int, _ yTop: Int) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        ctx.textPosition = CGPoint(x: CGFloat(x + 2), y: CGFloat(sh - yTop - 25))
        CTLineDraw(line, ctx)
    }
    for (i, (name, img)) in results.enumerated() {
        let c = i % cols, r = i / cols
        let x = pad + c * (cw + pad)
        var y = pad + r * (blockH + pad)
        ctx.interpolationQuality = .none
        if let part = img.cropping(to: crop) { ctx.draw(part, in: CGRect(x: x, y: sh - y - ch, width: cw, height: ch)) }
        y += ch
        label(name + " — 부분(1:1)", x, y)
        y += labelH + pad
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: x, y: sh - y - fh, width: fw, height: fh))
        ctx.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: CGFloat(x) + crop.minX * k, y: CGFloat(sh - y) - crop.maxY * k, width: crop.width * k, height: crop.height * k))
        y += fh
        label(name, x, y)
    }
    return ctx.makeImage()!
}

let args = CommandLine.arguments
if args.count >= 7 && args[1] == "--hires" {
    let out = args[2]
    let wh = args[3].split(separator: "x").compactMap { Int($0) }
    let cr = args[4].split(separator: ",").compactMap { Double($0) }
    guard wh.count == 2, cr.count == 4 else { print("usage: gfxshot --hires out.png WxH x,y,w,h 1x.png name=hires.png …"); exit(2) }
    let device = MTLCreateSystemDefaultDevice()!
    let queue = device.makeCommandQueue()!
    let base = loadTop(args[5])
    var entries: [(String, ScreenLook, (pixels: [UInt8], width: Int, height: Int)?)] = [
        ("1× · 선명하게", ScreenLook(), nil),
        ("1× · MetalFX(지금 기본)", ScreenLook(upscale: .metalFX), nil),
    ]
    for a in args[6...] {
        let p = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard p.count == 2 else { continue }
        entries.append((p[0], ScreenLook(upscale: .metalFX), loadTop(p[1])))   // 확대 방식이 MetalFX여도 고해상도 화면은 건너뛴다
    }
    var results: [(String, CGImage)] = []
    for (name, look, hi) in entries {
        let pipe = ScreenPipeline(device: device, pixelFormat: .bgra8Unorm)!
        pipe.look = look
        var hiTex: MTLTexture?
        if let hi {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: hi.width, height: hi.height, mipmapped: false)
            td.usage = .shaderRead
            hiTex = device.makeTexture(descriptor: td)!
            hi.pixels.withUnsafeBytes { hiTex!.replace(region: MTLRegionMake2D(0, 0, hi.width, hi.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: hi.width * 4) }
        }
        base.pixels.withUnsafeBytes { raw in pipe.upload([raw.baseAddress!, raw.baseAddress!], hires: [hiTex, nil]) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: wh[0], height: wh[1], mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cmd = queue.makeCommandBuffer()!
        pipe.encode(cmd, pass: pass, targetSize: CGSize(width: wh[0], height: wh[1]), rects: [CGRect(x: 0, y: 0, width: wh[0], height: wh[1])], screens: [0])
        cmd.commit()
        cmd.waitUntilCompleted()
        results.append((name, image(target)))
        print(name)
    }
    savePNG(sheet(results, crop: CGRect(x: cr[0], y: cr[1], width: cr[2], height: cr[3]), full: CGSize(width: wh[0], height: wh[1]),
                  cols: results.count), out)
    print(out)
    exit(0)
}
guard args.count >= 3 else { print("usage: gfxshot in.png outdir [WxH] [x,y,w,h]"); exit(2) }
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var W = 1216, H = 912
if args.count > 3 { let p = args[3].split(separator: "x").compactMap { Int($0) }; if p.count == 2 { W = p[0]; H = p[1] } }
var crop: CGRect?
if args.count > 4 { let p = args[4].split(separator: ",").compactMap { Double($0) }; if p.count == 4 { crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) } }

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
var pixels = loadBGRA(args[1])

let looks: [(String, String, ScreenLook)] = [
    ("1-sharp", "선명하게(이전 기본)", ScreenLook()),
    ("2-smooth", "부드럽게", ScreenLook(upscale: .smooth)),
    ("3-pixel", "픽셀 그대로", ScreenLook(upscale: .pixel)),
    ("4-pixelart", "도트 다듬기(Scale4x)", ScreenLook(upscale: .pixelArt)),
    ("5-metalfx", "MetalFX(Scale2x 뒤)", ScreenLook(upscale: .metalFX)),
    ("6-grid", "MetalFX + LCD 격자 약하게", ScreenLook(upscale: .metalFX, grid: 0.12)),
    ("7-vivid", "선명하게 + 생생하게", ScreenLook(tone: .vivid)),
    ("8-soft", "선명하게 + 차분하게", ScreenLook(tone: .soft)),
]

var results: [(String, CGImage)] = []
for (file, label, look) in looks {
    let pipe = ScreenPipeline(device: device, pixelFormat: .bgra8Unorm)!
    pipe.look = look
    pixels.withUnsafeBytes { raw in pipe.upload([raw.baseAddress!, raw.baseAddress!]) }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    let target = device.makeTexture(descriptor: td)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    let cmd = queue.makeCommandBuffer()!
    pipe.encode(cmd, pass: pass, targetSize: CGSize(width: W, height: H), rects: [CGRect(x: 0, y: 0, width: W, height: H)], screens: [0])
    cmd.commit()
    cmd.waitUntilCompleted()
    let img = image(target)
    savePNG(img, "\(outDir)/\(file).png")
    results.append((label, img))
    print("\(file): \(label)")
}

// 비교판: 같은 곳을 잘라 확대 없이(1:1) 나란히, 아래에 이름
if let crop {
    let cols = 4, pad = 12, labelH = 34
    let cw = Int(crop.width), ch = Int(crop.height)
    let rows = (results.count + cols - 1) / cols
    let sw = cols * cw + (cols + 1) * pad, sh = rows * (ch + labelH) + (rows + 1) * pad
    let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: sw, height: sh))
    ctx.interpolationQuality = .none
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    for (i, (label, img)) in results.enumerated() {
        let c = i % cols, r = i / cols
        let x = pad + c * (cw + pad)
        let yTop = pad + r * (ch + labelH + pad)
        guard let part = img.cropping(to: crop) else { continue }
        ctx.draw(part, in: CGRect(x: x, y: sh - yTop - ch, width: cw, height: ch))
        let s = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: CGFloat(x + 2), y: CGFloat(sh - yTop - ch - 25))
        CTLineDraw(line, ctx)
    }
    savePNG(ctx.makeImage()!, "\(outDir)/sheet.png")
    print("sheet.png")
}
