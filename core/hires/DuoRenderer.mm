// DuoRenderer.mm — 3D만 높은 해상도로 그리는 렌더러(DuoRenderer.h 참고).
// 줄 그리기 · 캡처 · 밝기 · 색 넓히기는 melonDS GPU_Soft.cpp와 같다. 더한 것: 줄마다 3D 표시(ctrl)를 모으고,
// VBlank에 합성 패스(HiresShaders.mm의 compose)로 고해상도 화면을 만든다. 바꾼 곳은 "DuoDS:" 표시.

#include "DuoRenderer.h"
#include "DuoRenderer2D.h"
#include "HiresMetal.h"
#include "Metal3D.h"

#include <cstring>

#include "NDS.h"
#include "GPU_ColorOp.h"

namespace melonDS
{

struct DuoRenderer::Compose
{
    id<MTLComputePipelineState> Pipe;
    id<MTLBuffer> Ctrl[2];          // [화면] 256 × 192 — 그리는 중인 프레임(뒷 버퍼)의 3D 표시
    id<MTLBuffer> Lines[2];         // [화면] 192 — 마스터 밝기 | 3D X 스크롤 << 16
    id<MTLTexture> Fb[2];           // 1× 결과를 올리는 곳
    id<MTLTexture> Out[2][3];       // [화면][돌려 쓰기] 고해상도 결과
    int Next[2] {};
    bool Has[2] {};                 // 그리는 중인 프레임의 그 화면에 3D 표시가 있다
    id<MTLTexture> Pending[2];      // VBlank에 합성한 것 — SwapBuffers 때 앞으로
    id<MTLTexture> Front[2];
    id<MTLCommandBuffer> Cmd;

    void Wait()
    {
        if (Cmd)
        {
            [Cmd waitUntilCompleted];
            Cmd = nil;
        }
    }
};

DuoRenderer::DuoRenderer(melonDS::NDS& nds, int scale)
    : Renderer(nds.GPU), ScaleFactor(scale < 1 ? 1 : scale > 4 ? 4 : scale)
{
    const size_t len = 256 * 192;
    Framebuffer[0][0] = new u32[len];
    Framebuffer[0][1] = new u32[len];
    Framebuffer[1][0] = new u32[len];
    Framebuffer[1][1] = new u32[len];
    BackBuffer = 0;
    Output3D = nullptr;
    memset(Ctrl3D, 0, sizeof(Ctrl3D));

    Rend2D_A = std::make_unique<DuoRenderer2D>(GPU.GPU2D_A, *this);
    Rend2D_B = std::make_unique<DuoRenderer2D>(GPU.GPU2D_B, *this);
    // 3D는 Init에서(Metal이 준비된 뒤)
}

DuoRenderer::~DuoRenderer()
{
    if (C) C->Wait();
    Rend3D.reset();   // 3D 렌더러가 Metal 객체를 쓰므로 먼저
    Rend3DMetal = nullptr;
    C.reset();
    Metal.reset();

    delete[] Framebuffer[0][0];
    delete[] Framebuffer[0][1];
    delete[] Framebuffer[1][0];
    delete[] Framebuffer[1][1];
}

bool DuoRenderer::Init()
{
    Metal = std::make_unique<HiresMetal>();
    if (!Metal->Init(Error)) return false;

    auto rend3d = std::make_unique<MetalRenderer3D>(GPU.GPU3D, *Metal);
    rend3d->SetScaleFactor(ScaleFactor);
    if (!rend3d->Init())
    {
        Error = rend3d->LastError();
        return false;
    }
    Rend3DMetal = rend3d.get();
    Rend3D = std::move(rend3d);

    C = std::make_unique<Compose>();
    id<MTLFunction> f = Metal->Function("compose", Error);
    NSError* e = nil;
    if (!f || !(C->Pipe = [Metal->Device newComputePipelineStateWithFunction:f error:&e]))
    {
        if (e) Error = std::string("합성 패스: ") + e.localizedDescription.UTF8String;
        return false;
    }
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:256 height:192 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    for (int s = 0; s < 2; s++)
    {
        C->Ctrl[s] = [Metal->Device newBufferWithLength:256 * 192 * 4 options:MTLResourceStorageModeShared];
        C->Lines[s] = [Metal->Device newBufferWithLength:192 * 4 options:MTLResourceStorageModeShared];
        C->Fb[s] = [Metal->Device newTextureWithDescriptor:td];
        if (!C->Ctrl[s] || !C->Lines[s] || !C->Fb[s])
        {
            Error = "합성 버퍼를 만들 수 없음";
            return false;
        }
        memset(C->Ctrl[s].contents, 0, 256 * 192 * 4);
        memset(C->Lines[s].contents, 0, 192 * 4);
    }
    return true;
}

void DuoRenderer::Reset()
{
    const size_t len = 256 * 192 * sizeof(u32);
    memset(Framebuffer[0][0], 0, len);
    memset(Framebuffer[0][1], 0, len);
    memset(Framebuffer[1][0], 0, len);
    memset(Framebuffer[1][1], 0, len);

    Rend2D_A->Reset();
    Rend2D_B->Reset();
    Rend3D->Reset();

    C->Wait();
    for (int s = 0; s < 2; s++)
    {
        C->Has[s] = false;
        C->Pending[s] = nil;
        C->Front[s] = nil;
    }
}

void DuoRenderer::Stop()
{
    // clear framebuffers to black
    const size_t len = 256 * 192 * sizeof(u32);
    memset(Framebuffer[0][0], 0, len);
    memset(Framebuffer[0][1], 0, len);
    memset(Framebuffer[1][0], 0, len);
    memset(Framebuffer[1][1], 0, len);
    if (C)
    {
        C->Wait();
        for (int s = 0; s < 2; s++) C->Front[s] = C->Pending[s] = nil;
    }
}

void DuoRenderer::PostSavestate()
{
    // 텍스처 캐시를 비우고(GL 렌더러와 같이) 불러온 상태의 3D를 바로 다시 그린다
    Rend3D->Reset();
    Rend3D->RenderFrame();
}

void DuoRenderer::SetRenderSettings(RendererSettings& settings)
{
    SetScaleFactor(settings.ScaleFactor);
}

void DuoRenderer::SetScaleFactor(int scale)
{
    if (scale < 1) scale = 1;
    if (scale > 4) scale = 4;
    ScaleFactor = scale;
    if (Rend3DMetal) Rend3DMetal->SetScaleFactor(scale);
}


void DuoRenderer::DrawScanline(u32 line)
{
    u32 *dstA, *dstB;
    u32 dstoffset = 256 * line;
    int screenA;   // DuoDS: 엔진 A가 그리는 화면(0 위 · 1 아래)
    if (GPU.ScreenSwap)
    {
        dstA = &Framebuffer[BackBuffer][0][dstoffset];
        dstB = &Framebuffer[BackBuffer][1][dstoffset];
        screenA = 0;
    }
    else
    {
        dstA = &Framebuffer[BackBuffer][1][dstoffset];
        dstB = &Framebuffer[BackBuffer][0][dstoffset];
        screenA = 1;
    }

    // DuoDS: 지난 프레임의 합성이 표시 버퍼를 다 읽은 뒤에 고쳐 쓴다
    if (line == 0) C->Wait();
    memset(Ctrl3D, 0, sizeof(Ctrl3D));

    // the position used for drawing operations is based on VCOUNT
    u32 vline = GPU.VCount;
    if (vline < 192)
    {
        // retrieve 3D output
        Output3D = Rend3D->GetLine(vline);

        // draw BG/OBJ layers
        Rend2D_A->DrawScanline(vline);
        Rend2D_B->DrawScanline(vline);

        // draw the final screen output
        DrawScanlineA(vline, dstA);
        DrawScanlineB(vline, dstB);

        // perform display capture if enabled
        if (GPU.CaptureEnable)
            DoCapture(vline);
    }
    else
    {
        // if scanlines outside VCOUNT range 0..191 were to be visible, fill them white
        // this may happen if VCOUNT is written to during active display
        // the actual hardware behavior depends on the screen model, and suggests that
        // no video signal is output for such scanlines

        for (int i = 0; i < 256; i++)
        {
            dstA[i] = 0x3F3F3F;
            dstB[i] = 0x3F3F3F;
        }
    }

    if (GPU.ScreensEnabled)
    {
        // expand the color from 6-bit to 8-bit
        ExpandColor(dstA);
        ExpandColor(dstB);
    }
    else
    {
        // if the screens are disabled: fill the framebuffer black
        for (int i = 0; i < 256; i++)
        {
            dstA[i] = 0xFF000000;
            dstB[i] = 0xFF000000;
        }
    }

    // DuoDS: 이 줄의 3D 표시 — 보통 표시(그래픽 모드)일 때만 3D가 보인다
    u32* ctrlA = (u32*)C->Ctrl[screenA].contents + dstoffset;
    u32* ctrlB = (u32*)C->Ctrl[screenA ^ 1].contents + dstoffset;
    memset(ctrlB, 0, 256 * 4);
    bool shown = vline < 192 && GPU.ScreensEnabled && ((GPU.GPU2D_A.DispCnt >> 16) & 0x3) == 1;
    if (shown)
    {
        memcpy(ctrlA, Ctrl3D, sizeof(Ctrl3D));
        if (!C->Has[screenA])
        {
            for (int i = 0; i < 256; i++)
                if (Ctrl3D[i]) { C->Has[screenA] = true; break; }
        }
    }
    else
        memset(ctrlA, 0, 256 * 4);
    ((u32*)C->Lines[screenA].contents)[line] = GPU.MasterBrightnessA | ((u32)GPU.GPU3D.GetRenderXPos() << 16);
}

void DuoRenderer::DrawSprites(u32 line)
{
    Rend2D_A->DrawSprites(line);
    Rend2D_B->DrawSprites(line);
}

void DuoRenderer::DrawScanlineA(u32 line, u32* dst)
{
    u32 dispcnt = GPU.GPU2D_A.DispCnt;
    switch ((dispcnt >> 16) & 0x3)
    {
    case 0: // screen off
        {
            for (int i = 0; i < 256; i++)
                dst[i] = 0x3F3F3F;
        }
        return;

    case 1: // regular display
        {
            for (int i = 0; i < 256; i+=2)
                *(u64*)&dst[i] = *(u64*)&Output2D[0][i];
        }
        break;

    case 2: // VRAM display
        {
            u32 vrambank = (dispcnt >> 18) & 0x3;
            if (GPU.VRAMMap_LCDC & (1<<vrambank))
            {
                u16* vram = (u16*)GPU.VRAM[vrambank];
                vram = &vram[line * 256];

                for (int i = 0; i < 256; i++)
                {
                    u16 color = vram[i];
                    u8 r = (color & 0x001F) << 1;
                    u8 g = (color & 0x03E0) >> 4;
                    u8 b = (color & 0x7C00) >> 9;

                    dst[i] = r | (g << 8) | (b << 16);
                }
            }
            else
            {
                for (int i = 0; i < 256; i++)
                    dst[i] = 0;
            }
        }
        break;

    case 3: // FIFO display
        {
            for (int i = 0; i < 256; i++)
            {
                u16 color = GPU.DispFIFOBuffer[i];
                u8 r = (color & 0x001F) << 1;
                u8 g = (color & 0x03E0) >> 4;
                u8 b = (color & 0x7C00) >> 9;

                dst[i] = r | (g << 8) | (b << 16);
            }
        }
        break;
    }

    ApplyMasterBrightness(GPU.MasterBrightnessA, dst);
}

void DuoRenderer::DrawScanlineB(u32 line, u32* dst)
{
    u32 dispcnt = GPU.GPU2D_B.DispCnt;
    switch ((dispcnt >> 16) & 0x1)
    {
    case 0: // screen off
        {
            for (int i = 0; i < 256; i++)
                dst[i] = 0xFF3F3F3F;
        }
        return;

    case 1: // regular display
        {
            for (int i = 0; i < 256; i+=2)
                *(u64*)&dst[i] = *(u64*)&Output2D[1][i];
        }
        break;
    }

    ApplyMasterBrightness(GPU.MasterBrightnessB, dst);
}

void DuoRenderer::DoCapture(u32 line)
{
    u32 captureCnt = GPU.CaptureCnt;

    u32 width, height;
    u32 sz = (captureCnt >> 20) & 0x3;
    if (sz == 0)
    {
        width = 128;
        height = 128;
    }
    else
    {
        width = 256;
        height = 64 * sz;
    }

    if (line >= height)
        return;

    u32 dstvram = (captureCnt >> 16) & 0x3;
    if (!(GPU.VRAMMap_LCDC & (1<<dstvram)))
        return;

    u16* dst = (u16*)GPU.VRAM[dstvram];
    u32 dstaddr = (((captureCnt >> 18) & 0x3) << 14) + (line * width);
    dst += (dstaddr & 0xFFFF);

    u32* srcA;
    if (captureCnt & (1<<24))
        srcA = Output3D;
    else
        srcA = Output2D[0];

    u16* srcB = nullptr;
    if (captureCnt & (1<<25))
        srcB = GPU.DispFIFOBuffer;
    else
    {
        u32 dispcnt = GPU.GPU2D_A.DispCnt;
        u32 srcvram = (dispcnt >> 18) & 0x3;
        if (GPU.VRAMMap_LCDC & (1<<srcvram))
        {
            srcB = (u16*)GPU.VRAM[srcvram];

            u32 offset = line * 256;
            if (((dispcnt >> 16) & 0x3) != 2)
                offset += (((captureCnt >> 26) & 0x3) << 14);

            srcB += (offset & 0xFFFF);
        }
    }

    static_assert(VRAMDirtyGranularity == 512);
    GPU.VRAMDirty[dstvram][(dstaddr * 2) / VRAMDirtyGranularity] = true;

    switch ((captureCnt >> 29) & 0x3)
    {
    case 0: // source A
        {
            for (u32 i = 0; i < width; i++)
            {
                u32 val = srcA[i];

                u32 r = (val >> 1) & 0x1F;
                u32 g = (val >> 9) & 0x1F;
                u32 b = (val >> 17) & 0x1F;
                u32 a = ((val >> 24) != 0) ? 0x8000 : 0;

                dst[i] = r | (g << 5) | (b << 10) | a;
            }
        }
        break;

    case 1: // source B
        {
            if (srcB)
            {
                for (u32 i = 0; i < width; i++)
                    dst[i] = srcB[i];
            }
            else
            {
                for (u32 i = 0; i < width; i++)
                    dst[i] = 0;
            }
        }
        break;

    case 2: // sources A+B
    case 3:
        {
            u32 eva = captureCnt & 0x1F;
            u32 evb = (captureCnt >> 8) & 0x1F;

            // checkme
            if (eva > 16) eva = 16;
            if (evb > 16) evb = 16;

            if (srcB)
            {
                for (u32 i = 0; i < width; i++)
                {
                    u32 val = srcA[i];

                    u32 rA = (val >> 1) & 0x1F;
                    u32 gA = (val >> 9) & 0x1F;
                    u32 bA = (val >> 17) & 0x1F;
                    u32 aA = ((val >> 24) != 0) ? 1 : 0;

                    val = srcB[i];

                    u32 rB = val & 0x1F;
                    u32 gB = (val >> 5) & 0x1F;
                    u32 bB = (val >> 10) & 0x1F;
                    u32 aB = val >> 15;

                    u32 rD = ((rA * aA * eva) + (rB * aB * evb) + 8) >> 4;
                    u32 gD = ((gA * aA * eva) + (gB * aB * evb) + 8) >> 4;
                    u32 bD = ((bA * aA * eva) + (bB * aB * evb) + 8) >> 4;
                    u32 aD = (eva>0 ? aA : 0) | (evb>0 ? aB : 0);

                    if (rD > 0x1F) rD = 0x1F;
                    if (gD > 0x1F) gD = 0x1F;
                    if (bD > 0x1F) bD = 0x1F;

                    dst[i] = rD | (gD << 5) | (bD << 10) | (aD << 15);
                }
            }
            else
            {
                for (u32 i = 0; i < width; i++)
                {
                    u32 val = srcA[i];

                    u32 rA = (val >> 1) & 0x1F;
                    u32 gA = (val >> 9) & 0x1F;
                    u32 bA = (val >> 17) & 0x1F;
                    u32 aA = ((val >> 24) != 0) ? 1 : 0;

                    u32 rD = ((rA * aA * eva) + 8) >> 4;
                    u32 gD = ((gA * aA * eva) + 8) >> 4;
                    u32 bD = ((bA * aA * eva) + 8) >> 4;
                    u32 aD = (eva>0 ? aA : 0);

                    dst[i] = rD | (gD << 5) | (bD << 10) | (aD << 15);
                }
            }
        }
        break;
    }
}

void DuoRenderer::ApplyMasterBrightness(u16 regval, u32* dst)
{
    u16 mode = regval >> 14;
    if (mode == 1)
    {
        // up
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;

        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessUp(dst[i], factor, 0x0);
    }
    else if (mode == 2)
    {
        // down
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;

        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessDown(dst[i], factor, 0xF);
    }
}

void DuoRenderer::ExpandColor(u32* dst)
{
    // convert to 32-bit BGRA
    // note: 32-bit RGBA would be more straightforward, but
    // BGRA seems to be more compatible (Direct2D soft, cairo...)
    for (int i = 0; i < 256; i+=2)
    {
        u64 c = *(u64*)&dst[i];

        u64 r = (c << 18) & 0xFC000000FC0000;
        u64 g = (c << 2) & 0xFC000000FC00;
        u64 b = (c >> 14) & 0xFC000000FC;
        c = r | g | b;

        *(u64*)&dst[i] = c | ((c & 0x00C0C0C000C0C0C0) >> 6) | 0xFF000000FF000000;
    }
}


bool DuoRenderer::GetFramebuffers(void** top, void** bottom)
{
    int frontbuf = BackBuffer ^ 1;
    *top = Framebuffer[frontbuf][0];
    *bottom = Framebuffer[frontbuf][1];
    return true;
}

// ── DuoDS: 합성 ──────────────────────────────────────────

void DuoRenderer::VBlank()
{
    // 3D 표시가 있던 화면만, 1× 결과 + 고해상도 3D → 고해상도 그림. 3D 그리기와 같은 큐라 그 뒤에 돈다
    C->Wait();
    id<MTLCommandBuffer> cmd = nil;
    const int W = 256 * ScaleFactor, H = 192 * ScaleFactor;
    id<MTLTexture> color3d = (__bridge id<MTLTexture>)Rend3DMetal->ColorTexture();
    for (int s = 0; s < 2; s++)
    {
        C->Pending[s] = nil;
        if (!C->Has[s] || !color3d || (int)color3d.width != W) continue;

        __strong id<MTLTexture>& out = C->Out[s][C->Next[s]];
        if (!out || (int)out.width != W)
        {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            td.storageMode = MTLStorageModeShared;
            out = [Metal->Device newTextureWithDescriptor:td];
            if (!out) continue;
        }
        C->Next[s] = (C->Next[s] + 1) % 3;

        [C->Fb[s] replaceRegion:MTLRegionMake2D(0, 0, 256, 192) mipmapLevel:0
                      withBytes:Framebuffer[BackBuffer][s] bytesPerRow:256 * 4];

        if (!cmd) cmd = [Metal->Queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:C->Pipe];
        [enc setTexture:color3d atIndex:0];
        [enc setTexture:C->Fb[s] atIndex:1];
        [enc setTexture:out atIndex:2];
        [enc setBuffer:C->Ctrl[s] offset:0 atIndex:0];
        [enc setBuffer:C->Lines[s] offset:0 atIndex:1];
        u32 scale = ScaleFactor;
        [enc setBytes:&scale length:sizeof(scale) atIndex:2];
        NSUInteger tw = C->Pipe.threadExecutionWidth;
        NSUInteger th = C->Pipe.maxTotalThreadsPerThreadgroup / tw;
        [enc dispatchThreadgroups:MTLSizeMake((W + tw - 1) / tw, (H + th - 1) / th, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [enc endEncoding];
        C->Pending[s] = out;
    }
    if (cmd)
    {
        [cmd commit];
        C->Cmd = cmd;
    }
}

void DuoRenderer::SwapBuffers()
{
    for (int s = 0; s < 2; s++)
    {
        C->Front[s] = C->Pending[s];
        C->Pending[s] = nil;
        C->Has[s] = false;
    }
    BackBuffer ^= 1;
}

void DuoRenderer::WaitFrame()
{
    if (C) C->Wait();
}

void* DuoRenderer::ScreenTexture(int screen, int* width, int* height) const
{
    if (!C || screen < 0 || screen > 1 || !C->Front[screen]) return nullptr;
    id<MTLTexture> t = C->Front[screen];
    if (width) *width = (int)t.width;
    if (height) *height = (int)t.height;
    return (__bridge void*)t;
}

bool DuoRenderer::ReadScreen(int screen, std::vector<u32>& out, int& width, int& height) const
{
    if (!C || screen < 0 || screen > 1 || !C->Front[screen]) return false;
    C->Wait();
    id<MTLTexture> t = C->Front[screen];
    width = (int)t.width;
    height = (int)t.height;
    out.resize((size_t)width * height);
    [t getBytes:out.data() bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    return true;
}

}
