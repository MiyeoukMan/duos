// 시뮬레이터 녹화(mp4)를 GIF로 — 외부 도구 없이 AVFoundation + ImageIO만.
//   swift tools/video2gif.swift 입력.mp4 출력.gif [폭=480] [초당=15] [시작초=0] [끝초=끝] [돌리기=0|90|-90]
//   녹화의 방향 정보(preferredTransform)는 적용된다 — 돌리기는 그래도 틀어져 있을 때만.
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: video2gif in.mp4 out.gif [width] [fps] [start] [end]"); exit(2) }
let width = args.count > 3 ? Double(args[3])! : 480
let fps = args.count > 4 ? Double(args[4])! : 15
let start = args.count > 5 ? Double(args[5])! : 0

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let duration = CMTimeGetSeconds(asset.duration)
let end = args.count > 6 ? min(Double(args[6])!, duration) : duration
let rotate = args.count > 7 ? Double(args[7])! : 0

func rotated(_ img: CGImage) -> CGImage {
    guard rotate != 0 else { return img }
    let w = img.height, h = img.width
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    ctx.rotate(by: CGFloat(rotate * .pi / 180))
    ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
    return ctx.makeImage()!
}
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: width * 4, height: width)

let count = max(1, Int((end - start) * fps))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.gif.identifier as CFString, count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
var written = 0
for i in 0..<count {
    let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
    if let img = try? gen.copyCGImage(at: t, actualTime: nil) {
        CGImageDestinationAddImage(dest, rotated(img), frameProps)
        written += 1
    }
}
CGImageDestinationFinalize(dest)
print("\(written) frames, \(String(format: "%.1f", end - start))s → \(args[2])")
