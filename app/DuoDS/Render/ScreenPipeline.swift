import CoreGraphics
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// 화면 꾸미기 설정(그래픽 옵션). 앱은 Settings에서, 맥 비교 도구(tools/gfxshot)는 직접 만든다.
struct ScreenLook: Equatable {
    /// 확대 방식 — Settings.Filter와 같은 번호
    enum Upscale: Int {
        case sharp = 0      // 선명한 이중 선형(픽셀 경계만 한 화면 픽셀 폭으로 섞음)
        case smooth         // 이중 선형
        case pixel          // 가장 가까운 픽셀
        case pixelArt       // Scale2x 두 번(= Scale4x) 뒤 선명하게 — 2D 도트의 계단을 다듬는다
        case metalFX        // Scale2x 한 번 뒤 MetalFX 공간 업스케일러로 화면 크기까지(바로 하면 도트 외곽선이 구슬처럼 울퉁불퉁)
    }
    enum Tone: Int {
        case original = 0
        case vivid          // 채도를 올린다
        case soft           // 채도를 낮추고 어두운 곳을 살짝 올린다(옛 LCD 느낌 — 실기 색을 잰 값은 아님)
    }

    var upscale = Upscale.sharp
    var tone = Tone.original
    /// LCD 격자 세기(0 = 끔) — DS 픽셀 경계를 어둡게
    var grid: Float = 0
    /// 잔상: 지난 프레임과 반씩 섞는다(번갈아 깜빡이는 반투명 · LCD 잔상 흉내)
    var frameBlend = false
}

/// DS 화면 두 장을 그리는 그래픽 단계 — 앱(ScreenRenderer)과 맥 도구가 같이 쓴다.
/// 새 프레임 → [잔상 섞기] → [확대: Scale4x · MetalFX] → 마지막 패스(샘플링 · 색감 · LCD 격자)로 화면 자리에.
/// 3D 해상도가 2배 이상이면 3D가 있던 화면은 코어가 고해상도로 그린 그림이 들어오고, 그 화면은 확대 단계를 건너뛴다.
/// 중간 결과는 프레임이나 설정 · 자리 크기가 바뀔 때만 다시 만든다(화면은 120Hz로 그려도 DS는 60프레임).
final class ScreenPipeline {
    static let width = 256, height = 192

    let device: MTLDevice
    private let finalState: MTLRenderPipelineState
    private let blendState: MTLComputePipelineState
    private let scale2xState: MTLComputePipelineState

    private var cur: [MTLTexture]
    private var prev: [MTLTexture]
    private var hasPrev = false
    private lazy var blended = (0..<2).map { _ in makeTexture(Self.width, Self.height, [.shaderRead, .shaderWrite]) }
    private lazy var x2 = (0..<2).map { _ in makeTexture(Self.width * 2, Self.height * 2, [.shaderRead, .shaderWrite]) }
    private lazy var x4 = (0..<2).map { _ in makeTexture(Self.width * 4, Self.height * 4, [.shaderRead, .shaderWrite]) }
    #if canImport(MetalFX)
    private var scalers: [MTLFXSpatialScaler?] = [nil, nil]
    #endif
    private var scalerOut: [MTLTexture?] = [nil, nil]
    /// 고해상도 그림(3D 내부 해상도 — 3D가 있던 화면만). 코어 텍스처는 코어가 돌려 쓰므로 받은 그리기 안에서 내 것으로 복사한다
    private var pendingHires: [MTLTexture?]?
    private var hiCur: [MTLTexture?] = [nil, nil]
    private var hiPrev: [MTLTexture?] = [nil, nil]
    private var hiBlended: [MTLTexture?] = [nil, nil]
    private var hasHires = [false, false]
    /// 화면마다 마지막 패스가 읽을 것
    private var stage: [MTLTexture]
    private var dirty = true
    private var stageSizes: [CGSize] = [.zero, .zero]

    var look = ScreenLook() { didSet { if look != oldValue { dirty = true } } }

    static func metalFXSupported(_ device: MTLDevice) -> Bool {
        #if canImport(MetalFX)
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
        return false   // 시뮬레이터 SDK에는 MetalFX가 없다
        #endif
    }
    /// 이 기기에서 MetalFX를 쓸 수 있나(시뮬레이터 · 옛 기기는 아님)
    static let metalFXAvailable: Bool = MTLCreateSystemDefaultDevice().map(metalFXSupported) ?? false

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        // 셰이더는 실행할 때 컴파일한다(빌드 맥에 Metal 툴체인이 없어도 되게)
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let blend = library.makeFunction(name: "blend_frames"), let s2x = library.makeFunction(name: "scale2x"),
              let blendState = try? device.makeComputePipelineState(function: blend),
              let scale2xState = try? device.makeComputePipelineState(function: s2x) else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "quad_vertex")
        desc.fragmentFunction = library.makeFunction(name: "final_fragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        guard let finalState = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.finalState = finalState
        self.blendState = blendState
        self.scale2xState = scale2xState
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        td.usage = .shaderRead
        cur = (0..<2).compactMap { _ in device.makeTexture(descriptor: td) }
        prev = (0..<2).compactMap { _ in device.makeTexture(descriptor: td) }
        stage = cur
    }

    private func makeTexture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = usage
        td.storageMode = .private
        return device.makeTexture(descriptor: td)!
    }

    /// 새 프레임(BGRA 8비트 256 × 192 두 장 — 0 위 · 1 아래). `hires[i]`가 있으면 그 화면은 그 고해상도 그림(BGRA 8비트)으로 그린다
    func upload(_ screens: [UnsafeRawPointer], hires: [MTLTexture?] = [nil, nil]) {
        swap(&cur, &prev)
        let region = MTLRegionMake2D(0, 0, Self.width, Self.height)
        for i in 0..<2 {
            cur[i].replace(region: region, mipmapLevel: 0, withBytes: screens[i], bytesPerRow: Self.width * 4)
            if !hasPrev { prev[i].replace(region: region, mipmapLevel: 0, withBytes: screens[i], bytesPerRow: Self.width * 4) }
        }
        hasPrev = true
        pendingHires = hires
        dirty = true
    }

    /// 그리기. `rects`는 타깃 픽셀 좌표의 화면 자리, `screens[i]`는 그 자리에 그릴 DS 화면(0 위 · 1 아래).
    /// `pass`의 색 붙임 자리 크기가 `targetSize`.
    func encode(_ cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, targetSize: CGSize, rects: [CGRect], screens: [Int]) {
        // 화면마다 자리 크기(MetalFX 출력 크기)
        var sizes: [CGSize] = [.zero, .zero]
        for (r, s) in zip(rects, screens) where r.width >= 1 && r.height >= 1 {
            sizes[s] = CGSize(width: r.width.rounded(), height: r.height.rounded())
        }
        if sizes != stageSizes { stageSizes = sizes; dirty = true }
        if dirty { prepare(cmd, sizes: sizes) }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(finalState)
        for (rect, s) in zip(rects, screens) where rect.width >= 1 && targetSize.width > 0 {
            let tex = stage[s]
            let mode: Int32
            switch look.upscale {
            case .smooth: mode = 1
            case .pixel: mode = 2
            case .metalFX where tex.width == Int(sizes[s].width): mode = 1   // 화면 크기 그대로 — 1:1
            default: mode = 0
            }
            var u = FinalUniforms(
                rect: SIMD4(Float(rect.minX / targetSize.width) * 2 - 1, 1 - Float(rect.minY / targetSize.height) * 2,
                            Float(rect.maxX / targetSize.width) * 2 - 1, 1 - Float(rect.maxY / targetSize.height) * 2),
                texSize: SIMD2(Float(tex.width), Float(tex.height)),
                scale: SIMD2(Float(rect.width) / Float(tex.width), Float(rect.height) / Float(tex.height)),
                dsScale: SIMD2(Float(rect.width) / Float(Self.width), Float(rect.height) / Float(Self.height)),
                mode: mode, tone: Int32(look.tone.rawValue), grid: look.grid, pad: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FinalUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<FinalUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private struct FinalUniforms {
        var rect: SIMD4<Float>
        var texSize: SIMD2<Float>
        var scale: SIMD2<Float>
        var dsScale: SIMD2<Float>
        var mode: Int32
        var tone: Int32
        var grid: Float
        var pad: Float
    }

    /// 받은 고해상도 그림을 내 텍스처로 복사(이번 그리기 안에서 — 코어가 3장을 돌려 쓴다)
    private func copyHires(_ cmd: MTLCommandBuffer) {
        guard let pending = pendingHires else { return }
        pendingHires = nil
        var blit: MTLBlitCommandEncoder?
        for i in 0..<2 {
            guard let src = pending[i] else {
                hasHires[i] = false
                continue
            }
            swap(&hiCur[i], &hiPrev[i])
            if !hasHires[i] { hiPrev[i] = nil }   // 바로 전 프레임은 1×였다 — 잔상은 다음부터
            if hiCur[i]?.width != src.width || hiCur[i]?.height != src.height {
                hiCur[i] = makeTexture(src.width, src.height, [.shaderRead, .shaderWrite])
            }
            if blit == nil { blit = cmd.makeBlitCommandEncoder() }
            blit?.copy(from: src, to: hiCur[i]!)
            hasHires[i] = true
        }
        blit?.endEncoding()
    }

    /// 중간 결과(잔상 · 확대)를 만든다
    private func prepare(_ cmd: MTLCommandBuffer, sizes: [CGSize]) {
        dirty = false
        copyHires(cmd)
        var src = cur
        var hiSrc = hiCur
        if look.frameBlend, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blendState)
            for i in 0..<2 {
                if hasHires[i] {
                    guard let c = hiCur[i], let p = hiPrev[i], p.width == c.width, p.height == c.height else { continue }
                    if hiBlended[i]?.width != c.width || hiBlended[i]?.height != c.height {
                        hiBlended[i] = makeTexture(c.width, c.height, [.shaderRead, .shaderWrite])
                    }
                    enc.setTexture(c, index: 0)
                    enc.setTexture(p, index: 1)
                    enc.setTexture(hiBlended[i], index: 2)
                    dispatch(enc, blendState, c.width, c.height)
                    hiSrc[i] = hiBlended[i]
                } else {
                    enc.setTexture(cur[i], index: 0)
                    enc.setTexture(prev[i], index: 1)
                    enc.setTexture(blended[i], index: 2)
                    dispatch(enc, blendState, Self.width, Self.height)
                }
            }
            enc.endEncoding()
            src = blended
        }
        stage = src
        switch look.upscale {
        case .pixelArt:
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(scale2xState)
                for i in 0..<2 where !hasHires[i] {
                    enc.setTexture(src[i], index: 0)
                    enc.setTexture(x2[i], index: 1)
                    dispatch(enc, scale2xState, Self.width, Self.height)
                }
                for i in 0..<2 where !hasHires[i] {
                    enc.setTexture(x2[i], index: 0)
                    enc.setTexture(x4[i], index: 1)
                    dispatch(enc, scale2xState, Self.width * 2, Self.height * 2)
                }
                enc.endEncoding()
                stage = x4
            }
        case .metalFX:
            var input = src
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(scale2xState)
                for i in 0..<2 where !hasHires[i] {
                    enc.setTexture(src[i], index: 0)
                    enc.setTexture(x2[i], index: 1)
                    dispatch(enc, scale2xState, Self.width, Self.height)
                }
                enc.endEncoding()
                input = x2
            }
            #if canImport(MetalFX)
            for i in 0..<2 where sizes[i].width >= 1 && !hasHires[i] {
                guard let scaler = metalFXScaler(i, sizes[i], input[i]), let out = scalerOut[i] else { continue }
                scaler.colorTexture = input[i]
                scaler.outputTexture = out
                scaler.inputContentWidth = input[i].width
                scaler.inputContentHeight = input[i].height
                scaler.encode(commandBuffer: cmd)
                stage[i] = out
            }
            #endif
        default:
            break
        }
        // 고해상도 화면은 확대 없이 그대로 마지막 패스로
        for i in 0..<2 where hasHires[i] {
            if let t = hiSrc[i] { stage[i] = t }
        }
    }

    #if canImport(MetalFX)
    /// 화면 i용 MetalFX 스케일러 — 출력 크기가 바뀌면 다시 만든다. 안 되는 기기면 nil(선명하게로 그린다)
    private func metalFXScaler(_ i: Int, _ size: CGSize, _ input: MTLTexture) -> MTLFXSpatialScaler? {
        let w = Int(size.width), h = Int(size.height)
        if let s = scalers[i], s.outputWidth == w, s.outputHeight == h, s.inputWidth == input.width { return s }
        scalers[i] = nil
        scalerOut[i] = nil
        guard Self.metalFXSupported(device) else { return nil }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = input.width
        d.inputHeight = input.height
        d.outputWidth = w
        d.outputHeight = h
        d.colorTextureFormat = .bgra8Unorm
        d.outputTextureFormat = .bgra8Unorm
        d.colorProcessingMode = .perceptual   // 감마가 들어간 보통 색(sRGB 값)
        guard let s = d.makeSpatialScaler(device: device) else { return nil }
        scalers[i] = s
        scalerOut[i] = makeTexture(w, h, s.outputTextureUsage.union(.shaderRead))
        return s
    }
    #endif

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = state.threadExecutionWidth, th = max(1, state.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// ── 잔상: 이번 프레임과 지난 프레임을 반씩 ──
kernel void blend_frames(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                         texture2d<float, access::write> o [[texture(2)]], uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= o.get_width() || gid.y >= o.get_height()) return;
    o.write((a.read(gid) + b.read(gid)) * 0.5, gid);
}

// ── Scale2x(AdvMAME2x): 픽셀 하나 → 2×2. 위아래 · 좌우 이웃이 같은 색으로 이어지면 모서리를 그 색으로 —
// 도트 그림의 계단만 다듬고 색은 새로 만들지 않는다. 두 번 하면 Scale4x.
static bool same(float4 a, float4 b) { return all(abs(a.rgb - b.rgb) < 0.002); }
static float4 at(texture2d<float, access::read> t, int2 p)
{
    return t.read(uint2(clamp(p, int2(0), int2(t.get_width() - 1, t.get_height() - 1))));
}
kernel void scale2x(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    int2 p = int2(gid);
    float4 B = at(src, p + int2(0, -1)), D = at(src, p + int2(-1, 0)), E = at(src, p);
    float4 F = at(src, p + int2(1, 0)), H = at(src, p + int2(0, 1));
    float4 e0 = E, e1 = E, e2 = E, e3 = E;
    if (!same(B, H) && !same(D, F))
    {
        if (same(D, B)) e0 = D;
        if (same(B, F)) e1 = F;
        if (same(D, H)) e2 = D;
        if (same(H, F)) e3 = F;
    }
    uint2 q = gid * 2;
    dst.write(e0, q);
    dst.write(e1, q + uint2(1, 0));
    dst.write(e2, q + uint2(0, 1));
    dst.write(e3, q + uint2(1, 1));
}

// ── 마지막: 화면 자리에 사각형 하나. rect = (왼, 위, 오른, 아래) — NDC ──
struct FinalUniforms
{
    float4 rect;
    float2 texSize;   // 읽는 텍스처 크기(256×192 · 1024×768 · 화면 크기)
    float2 scale;     // 화면 픽셀 / 텍스처 픽셀
    float2 dsScale;   // 화면 픽셀 / DS 픽셀(LCD 격자용)
    int mode;         // 0 선명하게 · 1 이중 선형 · 2 가장 가까운 픽셀
    int tone;         // 0 원본 · 1 생생하게 · 2 차분하게
    float grid;       // LCD 격자 세기
    float pad;
};

struct VOut
{
    float4 pos [[position]];
    float2 uv;
};

vertex VOut quad_vertex(uint vid [[vertex_id]], constant FinalUniforms& u [[buffer(0)]])
{
    float2 corner = float2(vid & 1, vid >> 1);
    VOut o;
    o.pos = float4(mix(u.rect.x, u.rect.z, corner.x), mix(u.rect.y, u.rect.w, corner.y), 0, 1);
    o.uv = corner;
    return o;
}

fragment float4 final_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant FinalUniforms& u [[buffer(0)]])
{
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler near(filter::nearest, address::clamp_to_edge);
    float3 c;
    if (u.mode == 2) c = tex.sample(near, in.uv).rgb;
    else if (u.mode == 1) c = tex.sample(lin, in.uv).rgb;
    else
    {
        // 선명한 이중 선형: 픽셀 안쪽은 그대로, 경계 한 화면 픽셀 폭만 섞는다 — 정수 배가 아니어도 굵기가 고르다
        float2 texel = in.uv * u.texSize;
        float2 fl = floor(texel);
        float2 cd = fract(texel) - 0.5;
        float2 range = 0.5 - 0.5 / max(u.scale, float2(1.0));
        float2 f = (cd - clamp(cd, -range, range)) * u.scale + 0.5;
        c = tex.sample(lin, (fl + f) / u.texSize).rgb;
    }

    const float3 lumaW = float3(0.299, 0.587, 0.114);
    if (u.tone == 1)
    {
        float l = dot(c, lumaW);
        c = clamp(mix(float3(l), c, 1.25), 0.0, 1.0);
    }
    else if (u.tone == 2)
    {
        float l = dot(c, lumaW);
        c = mix(float3(l), c, 0.82);
        c = pow(c, float3(0.92)) * 0.97 + 0.015;
    }

    if (u.grid > 0)
    {
        // DS 픽셀 경계에서 한 화면 픽셀쯤 되는 선을 어둡게
        float2 f = fract(in.uv * float2(256.0, 192.0));
        float2 d = min(f, 1.0 - f) * u.dsScale;
        float edge = 1.0 - clamp(min(d.x, d.y) - 0.25, 0.0, 1.0);
        c *= 1.0 - u.grid * edge;
    }
    return float4(c, 1);
}
"""
}
