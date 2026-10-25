import MetalKit

/// 두 DS 화면을 MTKView에 그린다. 화면 자리(`topRect` · `bottomRect`)는 뷰 좌표(포인트).
/// 그리기 단계(잔상 · 확대 · 색감 · LCD 격자)는 ScreenPipeline — 맥 비교 도구(tools/gfxshot)와 같은 코드.
final class ScreenRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: ScreenPipeline
    private var seen: UInt64 = 0

    weak var frames: FrameStore?
    var topRect = CGRect.zero
    var bottomRect = CGRect.zero
    /// 위 · 아래 화면 바꾸기(위 자리에 아래 화면)
    var swapped = false
    var look: ScreenLook {
        get { pipeline.look }
        set { pipeline.look = newValue }
    }

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = ScreenPipeline(device: device, pixelFormat: view.colorPixelFormat) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
        view.device = device
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let frames {
            seen = frames.read(ifNewerThan: seen) { top, bottom, hires in
                pipeline.upload([UnsafeRawPointer(top), UnsafeRawPointer(bottom)], hires: hires)
            }
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), view.bounds.width > 0 else { return }
        let target = view.drawableSize
        let k = target.width / view.bounds.width
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }
        pipeline.encode(cmd, pass: pass, targetSize: target, rects: [px(topRect), px(bottomRect)], screens: swapped ? [1, 0] : [0, 1])
        cmd.present(drawable)
        cmd.commit()
    }
}
