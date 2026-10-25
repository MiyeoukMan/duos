// Metal3D.mm — melonDS의 OpenGL 3D 렌더러(GPU3D_OpenGL.cpp)를 Metal로 옮긴 것.
// 폴리곤 준비(정점 · 색인 · 묶음)와 그리는 순서 · 깊이/스텐실 규칙은 원본 그대로다. GL은 상태를 하나씩 켜고 끄는데
// Metal은 묶음(파이프라인 · 깊이/스텐실 상태)으로 정하므로, GL 상태를 GLState로 흉내 내고 그릴 때마다 맞는 묶음을 고른다.
// 원본과 달라진 곳은 "DuoDS:"로 표시했다. 화면 캡처를 텍스처로 쓰는 경로는 없다 — 캡처는 2D(소프트웨어)가 VRAM에 쓰고
// 텍스처 캐시가 보통 텍스처처럼 읽는다.

#include "Metal3D.h"
#include "HiresMetal.h"

#include <cstring>
#include <unordered_map>

#include "GPU.h"

namespace melonDS
{

// ── 텍스처 캐시 ──────────────────────────────────────────

u32 TexcacheMetalLoader::GenerateTexture(u32 width, u32 height, u32 layers)
{
    MTLTextureDescriptor* d = [MTLTextureDescriptor new];
    d.textureType = MTLTextureType2DArray;
    d.pixelFormat = MTLPixelFormatRGBA8Uint;   // 6비트 RGB · 5비트 알파(outputFmt_RGB6A5)
    d.width = width;
    d.height = height;
    d.arrayLength = layers;
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [M->Device newTextureWithDescriptor:d];
    if (!M->FreeHandles.empty())
    {
        u32 h = M->FreeHandles.back();
        M->FreeHandles.pop_back();
        M->Textures[h] = tex;
        return h;
    }
    M->Textures.push_back(tex);
    return (u32)M->Textures.size() - 1;
}

void TexcacheMetalLoader::UploadTexture(u32 handle, u32 width, u32 height, u32 layer, void* data)
{
    [M->Textures[handle] replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 slice:layer
                             withBytes:data bytesPerRow:width * 4 bytesPerImage:0];
}

void TexcacheMetalLoader::DeleteTexture(u32 handle)
{
    if (handle == 0 || handle >= M->Textures.size()) return;
    M->Textures[handle] = nil;
    M->FreeHandles.push_back(handle);
}

// ── Metal 객체 · GL 상태 흉내 ──────────────────────────────

namespace
{

// 셰이더의 Config3D와 같은 배치(GL의 std140 uConfig)
struct Config3D
{
    float ScreenSize[2];
    u32 DispCnt;
    u32 AlphaRef;
    float ToonColors[32][4];
    float EdgeColors[8][4];
    float FogColor[4];
    float FogDensity[34][4];
    u32 FogOffset;
    u32 FogShift;
    u32 EdgeOffset;
    u32 ClearPolyID;
    float ClearDepth;
    u32 Pad[3];
};
static_assert(sizeof(Config3D) == 1248, "셰이더와 배치가 같아야 한다");

struct ClearBitmapU
{
    float Offset[2];
    float ScreenSize[2];
    u32 PolyID;
    u32 Pad[3];
};

enum
{
    RenderMode_Opaque = 0,
    RenderMode_Translucent,
    RenderMode_ShadowMask,
};

// GL에서 그리기마다 바뀌던 상태
struct GLState
{
    bool Blend = false;
    bool BlendAlpha = false;   // true = (SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE), false = (ONE, ZERO, ONE, ONE) — 알파는 늘 MAX
    bool ColorMask0 = true;    // 색(첫 붙임)은 다 쓰거나 안 쓰거나
    u8 ColorMask1 = 0x7;       // 속성(둘째 붙임): R 폴리곤 ID · G 가장자리 · B 안개
    MTLCompareFunction DepthFunc = MTLCompareFunctionLess;
    bool DepthWrite = true;
    MTLCompareFunction StencilFunc = MTLCompareFunctionAlways;
    u8 StencilRef = 0;
    u8 StencilReadMask = 0xFF;
    u8 StencilWriteMask = 0xFF;
    MTLStencilOperation StencilFail = MTLStencilOperationKeep;
    MTLStencilOperation DepthFail = MTLStencilOperationKeep;
    MTLStencilOperation StencilPass = MTLStencilOperationKeep;
    int RenderMode = RenderMode_Opaque;
};

}

struct MetalRenderer3D::Objects
{
    id<MTLFunction> PolyVS[2], PolyFS[2];   // [W 버퍼]
    std::unordered_map<u32, id<MTLRenderPipelineState>> PolyPipes;
    std::unordered_map<u64, id<MTLDepthStencilState>> DepthStates;
    id<MTLRenderPipelineState> ClearBitmapPipe, StencilClearPipe, EdgePipe, FogPipe[2];
    id<MTLComputePipelineState> DownsamplePipe;

    id<MTLTexture> Color, Attr, Depth;
    id<MTLTexture> ClearBitmapTex[2];
    id<MTLBuffer> VertexBuf, IndexBuf, EdgeMaskBuf, Out1x;

    id<MTLCommandBuffer> LastCmd;
    id<MTLRenderCommandEncoder> Enc;

    Config3D Config {};
    GLState S;
    bool WBuffer = false;

    id<MTLRenderPipelineState> PolyPipe(id<MTLDevice> dev, u32 key)
    {
        auto it = PolyPipes.find(key);
        if (it != PolyPipes.end()) return it->second;

        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = PolyVS[key & 1];
        d.fragmentFunction = PolyFS[key & 1];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

        MTLRenderPipelineColorAttachmentDescriptor* c0 = d.colorAttachments[0];
        c0.writeMask = (key & 8) ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
        if (key & 2)
        {
            c0.blendingEnabled = YES;
            c0.rgbBlendOperation = MTLBlendOperationAdd;
            c0.alphaBlendOperation = MTLBlendOperationMax;
            c0.sourceRGBBlendFactor = (key & 4) ? MTLBlendFactorSourceAlpha : MTLBlendFactorOne;
            c0.destinationRGBBlendFactor = (key & 4) ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorZero;
            c0.sourceAlphaBlendFactor = MTLBlendFactorOne;
            c0.destinationAlphaBlendFactor = MTLBlendFactorOne;
        }
        // 속성 붙임: GL은 여기도 섞기를 켜지만 내보내는 알파가 늘 1이고 알파 칸은 안 쓰므로 섞지 않은 것과 같다
        MTLColorWriteMask m1 = MTLColorWriteMaskNone;
        if (key & 0x10) m1 |= MTLColorWriteMaskRed;
        if (key & 0x20) m1 |= MTLColorWriteMaskGreen;
        if (key & 0x40) m1 |= MTLColorWriteMaskBlue;
        d.colorAttachments[1].writeMask = m1;

        NSError* e = nil;
        id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        PolyPipes[key] = p;
        return p;
    }

    id<MTLDepthStencilState> DepthState(id<MTLDevice> dev, MTLCompareFunction dfunc, bool dwrite, MTLCompareFunction sfunc,
                                        u8 readMask, u8 writeMask, MTLStencilOperation sfail, MTLStencilOperation zfail,
                                        MTLStencilOperation zpass)
    {
        u64 key = (u64)dfunc | ((u64)dwrite << 3) | ((u64)sfunc << 4) | ((u64)readMask << 8) | ((u64)writeMask << 16) |
                  ((u64)sfail << 24) | ((u64)zfail << 28) | ((u64)zpass << 32);
        auto it = DepthStates.find(key);
        if (it != DepthStates.end()) return it->second;

        MTLStencilDescriptor* s = [MTLStencilDescriptor new];
        s.stencilCompareFunction = sfunc;
        s.stencilFailureOperation = sfail;
        s.depthFailureOperation = zfail;
        s.depthStencilPassOperation = zpass;
        s.readMask = readMask;
        s.writeMask = writeMask;
        MTLDepthStencilDescriptor* d = [MTLDepthStencilDescriptor new];
        d.depthCompareFunction = dfunc;
        d.depthWriteEnabled = dwrite;
        d.frontFaceStencil = s;
        d.backFaceStencil = s;
        id<MTLDepthStencilState> st = [dev newDepthStencilStateWithDescriptor:d];
        DepthStates[key] = st;
        return st;
    }
};

// ── GL 상태 바꾸기(원본의 gl* 부름과 한 줄씩 맞춘다) ─────────────

#define S (O->S)

static void StencilFunc(GLState& s, MTLCompareFunction f, u8 ref, u8 mask)
{
    s.StencilFunc = f;
    s.StencilRef = ref;
    s.StencilReadMask = mask;
}

static void StencilOp(GLState& s, MTLStencilOperation sfail, MTLStencilOperation zfail, MTLStencilOperation zpass)
{
    s.StencilFail = sfail;
    s.DepthFail = zfail;
    s.StencilPass = zpass;
}

static void ColorMask1(GLState& s, bool r, bool g, bool b)
{
    s.ColorMask1 = (r ? 1 : 0) | (g ? 2 : 0) | (b ? 4 : 0);
}

static constexpr MTLStencilOperation KEEP = MTLStencilOperationKeep;
static constexpr MTLStencilOperation REPLACE = MTLStencilOperationReplace;
static constexpr MTLStencilOperation INVERT = MTLStencilOperationInvert;
static constexpr MTLStencilOperation ZERO = MTLStencilOperationZero;

// ── 렌더러 ──────────────────────────────────────────────

MetalRenderer3D::MetalRenderer3D(melonDS::GPU3D& gpu3D, HiresMetal& metal)
    : Renderer3D(gpu3D), M(metal)
{
    ClearBitmap[0] = new u32[256*256];
    ClearBitmap[1] = new u32[256*256];
    Texcache = std::make_unique<TexcacheMetal>(gpu3D.GPU, TexcacheMetalLoader(&metal));
}

MetalRenderer3D::~MetalRenderer3D()
{
    WaitIdle();
    Texcache.reset();
    delete[] ClearBitmap[0];
    delete[] ClearBitmap[1];
}

bool MetalRenderer3D::Init()
{
    O = std::make_unique<Objects>();
    id<MTLDevice> dev = M.Device;

    for (int w = 0; w < 2; w++)
    {
        MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
        bool wbuf = w != 0;
        [cv setConstantValue:&wbuf type:MTLDataTypeBool atIndex:0];
        O->PolyVS[w] = M.Function("poly_vs", Error, cv);
        O->PolyFS[w] = M.Function(w ? "poly_fs_w" : "poly_fs_z", Error);
        if (!O->PolyVS[w] || !O->PolyFS[w]) return false;
    }
    id<MTLFunction> quad = M.Function("quad_vs", Error);
    id<MTLFunction> nothing = M.Function("nothing_fs", Error);
    id<MTLFunction> clearBmp = M.Function("clear_bitmap_fs", Error);
    id<MTLFunction> edge = M.Function("edge_fs", Error);
    id<MTLFunction> fog = M.Function("fog_fs", Error);
    id<MTLFunction> down = M.Function("downsample_3d", Error);
    if (!quad || !nothing || !clearBmp || !edge || !fog || !down) return false;

    NSError* e = nil;
    auto fail = [&](const char* what) {
        Error = std::string(what) + ": " + (e ? e.localizedDescription.UTF8String : "?");
        return false;
    };

    // 장면 패스(색 · 속성 · 깊이/스텐실)에서 쓰는 것
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = quad;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    d.fragmentFunction = clearBmp;
    if (!(O->ClearBitmapPipe = [dev newRenderPipelineStateWithDescriptor:d error:&e])) return fail("clear bitmap");
    d.fragmentFunction = nothing;
    d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    d.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
    if (!(O->StencilClearPipe = [dev newRenderPipelineStateWithDescriptor:d error:&e])) return fail("stencil clear");

    // 마지막 패스(색만) — 가장자리 표시 · 안개
    MTLRenderPipelineDescriptor* f = [MTLRenderPipelineDescriptor new];
    f.vertexFunction = quad;
    f.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    MTLRenderPipelineColorAttachmentDescriptor* c = f.colorAttachments[0];
    c.blendingEnabled = YES;
    c.rgbBlendOperation = MTLBlendOperationAdd;
    c.alphaBlendOperation = MTLBlendOperationAdd;
    f.fragmentFunction = edge;
    c.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;          // (SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ZERO, ONE)
    c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    c.sourceAlphaBlendFactor = MTLBlendFactorZero;
    c.destinationAlphaBlendFactor = MTLBlendFactorOne;
    if (!(O->EdgePipe = [dev newRenderPipelineStateWithDescriptor:f error:&e])) return fail("edge");
    f.fragmentFunction = fog;
    c.sourceRGBBlendFactor = MTLBlendFactorBlendColor;            // (CONSTANT_COLOR, ONE_MINUS_SRC_ALPHA) 둘 다
    c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    c.sourceAlphaBlendFactor = MTLBlendFactorBlendColor;
    c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    if (!(O->FogPipe[0] = [dev newRenderPipelineStateWithDescriptor:f error:&e])) return fail("fog");
    c.sourceRGBBlendFactor = MTLBlendFactorZero;                  // 알파만(DISP3DCNT 6번 비트): (ZERO, ONE, CONSTANT_COLOR, ONE_MINUS_SRC_ALPHA)
    c.destinationRGBBlendFactor = MTLBlendFactorOne;
    if (!(O->FogPipe[1] = [dev newRenderPipelineStateWithDescriptor:f error:&e])) return fail("fog alpha");

    if (!(O->DownsamplePipe = [dev newComputePipelineStateWithFunction:down error:&e])) return fail("downsample");

    // 지우기 비트맵(텍스처 슬롯 2 · 3)
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint
                                                                                   width:256 height:256 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    O->ClearBitmapTex[0] = [dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatR32Uint;
    O->ClearBitmapTex[1] = [dev newTextureWithDescriptor:td];

    O->VertexBuf = [dev newBufferWithLength:10240 * 7 * 4 options:MTLResourceStorageModeShared];
    O->IndexBuf = [dev newBufferWithLength:2048 * 40 * 4 options:MTLResourceStorageModeShared];
    O->EdgeMaskBuf = [dev newBufferWithLength:2048 * 40 options:MTLResourceStorageModeShared];
    O->Out1x = [dev newBufferWithLength:256 * 192 * 4 options:MTLResourceStorageModeShared];
    if (!O->VertexBuf || !O->IndexBuf || !O->EdgeMaskBuf || !O->Out1x || !O->ClearBitmapTex[0] || !O->ClearBitmapTex[1])
    {
        Error = "버퍼를 만들 수 없음";
        return false;
    }
    VertexBuffer = (u32*)O->VertexBuf.contents;
    IndexBuffer = (u32*)O->IndexBuf.contents;
    EdgeMask = (u8*)O->EdgeMaskBuf.contents;
    memset(O->Out1x.contents, 0, 256 * 192 * 4);

    int scale = ScaleFactor ? ScaleFactor : 2;   // 만들기 전에 정한 배율
    ScaleFactor = 0;
    SetScaleFactor(scale);
    return true;
}

void MetalRenderer3D::Reset()
{
    WaitIdle();
    Texcache->Reset();
    ClearBitmapDirty = 0x3;
    HasOutput = false;
}

void MetalRenderer3D::SetScaleFactor(int scale)
{
    if (scale < 1) scale = 1;
    if (scale > 4) scale = 4;
    if (!O) { ScaleFactor = scale; return; }   // Init이 만든다
    if (scale == ScaleFactor) return;
    WaitIdle();
    ScaleFactor = scale;
    ScreenW = 256 * scale;
    ScreenH = 192 * scale;

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:ScreenW height:ScreenH mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    O->Color = [M.Device newTextureWithDescriptor:td];
    O->Attr = [M.Device newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;   // GL은 DEPTH24_STENCIL8 — iOS엔 없다(24비트 깊이는 float32에 그대로 들어간다)
    O->Depth = [M.Device newTextureWithDescriptor:td];
    HasOutput = false;
}

void* MetalRenderer3D::ColorTexture() const
{
    return O ? (__bridge void*)O->Color : nullptr;
}

void MetalRenderer3D::WaitIdle()
{
    if (O && O->LastCmd)
    {
        [O->LastCmd waitUntilCompleted];
        O->LastCmd = nil;
    }
    Pending = false;
}

void MetalRenderer3D::SetupPolygon(MetalRenderer3D::RendererPolygon* rp, Polygon* polygon) const
{
    rp->PolyData = polygon;

    // render key: depending on what we're drawing
    // opaque polygons:
    // - depthfunc
    // -- alpha=0
    // regular translucent polygons:
    // - depthfunc
    // -- depthwrite
    // --- polyID
    // ---- need opaque
    // shadow mask polygons:
    // - depthfunc?????
    // shadow polygons:
    // - depthfunc
    // -- depthwrite
    // --- polyID

    rp->RenderKey = (polygon->Attr >> 14) & 0x1; // bit14 - depth func
    if (!polygon->IsShadowMask)
    {
        if (polygon->Translucent)
        {
            if (polygon->IsShadow) rp->RenderKey |= 0x20000;
            else                   rp->RenderKey |= 0x10000;
            rp->RenderKey |= (polygon->Attr >> 10) & 0x2; // bit11 - depth write
            rp->RenderKey |= (polygon->Attr >> 13) & 0x4; // bit15 - fog
            rp->RenderKey |= (polygon->Attr & 0x3F000000) >> 16; // polygon ID
            if ((polygon->Attr & 0x001F0000) == 0x001F0000) // need opaque
                rp->RenderKey |= 0x4000;
        }
        else
        {
            if ((polygon->Attr & 0x001F0000) == 0)
                rp->RenderKey |= 0x2;
            rp->RenderKey |= (polygon->Attr & 0x3F000000) >> 16; // polygon ID
        }
    }
    else
    {
        rp->RenderKey |= 0x30000;
    }

    u32 textype = (polygon->TexParam >> 26) & 0x7;
    u32 texattr = (polygon->TexParam >> 16) & 0x3FF;
    if (TexEnable && (textype != 0))
        rp->RenderKey |= (0x80000 | (texattr << 20));
}

u32* MetalRenderer3D::SetupVertex(const Polygon* poly, int vid, const Vertex* vtx, u32 vtxattr, u32 texlayer, u32* vptr) const
{
    u32 z = poly->FinalZ[vid];
    u32 w = poly->FinalW[vid];

    u32 alpha = (poly->Attr >> 16) & 0x1F;

    // Z should always fit within 16 bits, so it's okay to do this
    u32 zshift = 0;
    while (z > 0xFFFF) { z >>= 1; zshift++; }

    u32 x, y;
    if (ScaleFactor > 1)
    {
        x = (vtx->HiresPosition[0] * ScaleFactor) >> 4;
        y = (vtx->HiresPosition[1] * ScaleFactor) >> 4;
    }
    else
    {
        x = vtx->FinalPosition[0];
        y = vtx->FinalPosition[1];
    }

    *vptr++ = x | (y << 16);
    *vptr++ = z | (w << 16);

    *vptr++ =  (vtx->FinalColor[0] >> 1) |
              ((vtx->FinalColor[1] >> 1) << 8) |
              ((vtx->FinalColor[2] >> 1) << 16) |
              (alpha << 24);

    *vptr++ = (u16)vtx->TexCoords[0] | ((u16)vtx->TexCoords[1] << 16);

    *vptr++ = vtxattr | (zshift << 16);
    *vptr++ = texlayer;
    // DuoDS: 텍스처 반복(TexParam 16~19비트)을 크기 칸 12~15비트에 — GL은 그리기마다 텍스처 설정을 바꿨다
    *vptr++ = TextureWidth(poly->TexParam) | (((poly->TexParam >> 16) & 0xF) << 12) | (TextureHeight(poly->TexParam) << 16);

    return vptr;
}

void MetalRenderer3D::BuildPolygons(MetalRenderer3D::RendererPolygon* polygons, int npolys)
{
    u32* vptr = &VertexBuffer[0];
    u32 vidx = 0;

    u32 iidx = 0;

    u32 curtexparam = 0;
    u32 curtexpal = 0;
    u32 curtexid = 0;
    u32 curtexlayer = (u32)-1;

    for (int i = 0; i < npolys; i++)
    {
        RendererPolygon* rp = &polygons[i];
        Polygon* poly = rp->PolyData;

        rp->IndicesOffset = iidx;
        rp->NumIndices = 0;

        u32 vidx_first = vidx;

        u32 polyattr = poly->Attr;
        u32 texparam = poly->TexParam & ~0xC00F0000;
        u32 texpal = poly->TexPalette;

        u32 vtxattr = polyattr & 0x1F00C8F0;
        if (poly->FacingView) vtxattr |= (1<<8);
        if (poly->WBuffer)    vtxattr |= (1<<9);

        if ((texparam != curtexparam) || (texpal != curtexpal))
        {
            u32 textype = (texparam >> 26) & 0x7;
            if (TexEnable && (textype != 0))
            {
                // DuoDS: 화면 캡처 텍스처를 따로 고르는 경로는 뺐다(캡처는 VRAM에 있고 캐시가 보통 텍스처로 읽는다)
                u32* halp;
                Texcache->GetTexture(texparam, texpal, curtexid, curtexlayer, halp);
                curtexlayer |= 0xFFFF0000;
            }
            else
            {
                // no texture
                curtexid = 0;
                curtexlayer = (u32)-1;
            }

            curtexparam = texparam;
            curtexpal = texpal;
        }

        rp->TexID = curtexid;
        rp->TexRepeat = (poly->TexParam >> 16) & 0xF;

        // assemble vertices
        if (poly->Type == 1) // line
        {
            rp->Lines = true;

            u32 lastx, lasty;
            int nout = 0;
            for (u32 j = 0; j < poly->NumVertices; j++)
            {
                Vertex* vtx = poly->Vertices[j];

                if (j > 0)
                {
                    if (lastx == vtx->FinalPosition[0] &&
                        lasty == vtx->FinalPosition[1]) continue;
                }

                lastx = vtx->FinalPosition[0];
                lasty = vtx->FinalPosition[1];

                vptr = SetupVertex(poly, j, vtx, vtxattr, curtexlayer, vptr);

                if (nout == 0) EdgeMask[iidx] = 0x80;   // DuoDS: 선은 모두 가장자리
                IndexBuffer[iidx++] = vidx;
                rp->NumIndices++;

                vidx++;
                nout++;
                if (nout >= 2) break;
            }
        }
        else if (poly->NumVertices == 3) // regular triangle
        {
            rp->Lines = false;

            for (int j = 0; j < 3; j++)
            {
                Vertex* vtx = poly->Vertices[j];

                vptr = SetupVertex(poly, j, vtx, vtxattr, curtexlayer, vptr);
                vidx++;
            }

            // build a triangle
            EdgeMask[iidx] = 0x7;   // DuoDS: 세 변 모두 폴리곤 가장자리
            IndexBuffer[iidx++] = vidx_first;
            IndexBuffer[iidx++] = vidx - 2;
            IndexBuffer[iidx++] = vidx - 1;
            rp->NumIndices += 3;
        }
        else // quad, pentagon, etc
        {
            rp->Lines = false;

            // regular triangle-splitting
            // DuoDS: melonDS의 "better polygons"(가운데 점으로 나누기)는 옮기지 않았다 — 기본값이 꺼짐

            for (u32 j = 0; j < poly->NumVertices; j++)
            {
                Vertex* vtx = poly->Vertices[j];

                vptr = SetupVertex(poly, j, vtx, vtxattr, curtexlayer, vptr);

                if (j >= 2)
                {
                    // build a triangle
                    // DuoDS: (v0, v[j-1], v[j]) — v[j-1]~v[j]는 늘 가장자리, v0~v[j]는 마지막 삼각형, v0~v[j-1]은 첫 삼각형에서만
                    EdgeMask[iidx] = 0x1 | (j == poly->NumVertices - 1 ? 0x2 : 0) | (j == 2 ? 0x4 : 0);
                    IndexBuffer[iidx++] = vidx_first;
                    IndexBuffer[iidx++] = vidx - 1;
                    IndexBuffer[iidx++] = vidx;
                    rp->NumIndices += 3;
                }

                vidx++;
            }
        }
    }

    NumVertices = vidx;
    NumIndices = iidx;
}

// 묶음 하나를 지금 GL 상태대로 그린다
#define DRAW(rp, numindices) \
    do \
    { \
        u32 key = (O->WBuffer ? 1 : 0) | (S.Blend ? 2 : 0) | (S.BlendAlpha ? 4 : 0) | (S.ColorMask0 ? 8 : 0) | (S.ColorMask1 << 4); \
        id<MTLRenderPipelineState> pipe = O->PolyPipe(M.Device, key); \
        if (!pipe) break; \
        [O->Enc setRenderPipelineState:pipe]; \
        [O->Enc setDepthStencilState:O->DepthState(M.Device, S.DepthFunc, S.DepthWrite, S.StencilFunc, S.StencilReadMask, \
                                                   S.StencilWriteMask, S.StencilFail, S.DepthFail, S.StencilPass)]; \
        [O->Enc setStencilReferenceValue:S.StencilRef]; \
        int mode_ = S.RenderMode; \
        [O->Enc setFragmentBytes:&mode_ length:sizeof(mode_) atIndex:1]; \
        [O->Enc setFragmentTexture:M.Textures[(rp)->TexID] atIndex:0]; \
        if (M.Bary) \
        { \
            u32 edgeBase_[2] = { (rp)->IndicesOffset, (rp)->Lines ? 2u : 3u }; \
            [O->Enc setFragmentBytes:edgeBase_ length:sizeof(edgeBase_) atIndex:3]; \
        } \
        [O->Enc drawIndexedPrimitives:((rp)->Lines ? MTLPrimitiveTypeLine : MTLPrimitiveTypeTriangle) indexCount:(numindices) \
                            indexType:MTLIndexTypeUInt32 indexBuffer:O->IndexBuf indexBufferOffset:(rp)->IndicesOffset * 4]; \
    } while (false)

int MetalRenderer3D::RenderSinglePolygon(int i)
{
    const RendererPolygon* rp = &PolygonList[i];

    DRAW(rp, rp->NumIndices);

    return 1;
}

int MetalRenderer3D::RenderPolygonBatch(int i)
{
    const RendererPolygon* rp = &PolygonList[i];
    bool lines = rp->Lines;
    u32 renderkey = rp->RenderKey;
    u32 texid = rp->TexID;
    u32 texrepeat = rp->TexRepeat;
    int numpolys = 0;
    u32 numindices = 0;

    for (int iend = i; iend < NumFinalPolys; iend++)
    {
        const RendererPolygon* cur_rp = &PolygonList[iend];
        if (cur_rp->Lines != lines) break;
        if (cur_rp->RenderKey != renderkey) break;
        if (cur_rp->TexID != texid) break;
        if (cur_rp->TexRepeat != texrepeat) break;

        numpolys++;
        numindices += cur_rp->NumIndices;
    }

    DRAW(rp, numindices);
    return numpolys;
}

void MetalRenderer3D::RenderSceneChunk()
{
    O->WBuffer = GPU3D.RenderPolygonRAM[0]->WBuffer;

    bool fogenable = (GPU3D.RenderDispCnt & (1<<7)) != 0;

    // TODO: proper 'equal' depth test!
    // (has margin of +-0x200 in Z-buffer mode, +-0xFF in W-buffer mode)
    // for now we're using GL_LEQUAL to make it work to some extent

    // STENCIL BUFFER VALUES
    // 1111'1111 : background (clear plane)
    // 1111'1110 : shadow mask against background
    // 00pp'pppp : opaque polygon ID p
    // 01pp'pppp : translucent polygon ID p
    // 1___'____ : shadow mask

    // POLYGON ID BASED RENDERING RULES
    // opaque polygons: polygon ID ignored
    // translucent polygons: if dst is opaque
    //                       OR if dst is translucent and polygon ID is different
    // shadow polygons: if (dst is opaque AND dst opaque polygon ID is different)
    //                  OR (dst is translucent and dst translucent polygon ID is different)

    // pass 1: opaque pixels

    S.RenderMode = RenderMode_Opaque;

    ColorMask1(S, true, true, fogenable);

    S.DepthFunc = MTLCompareFunctionLess;
    S.DepthWrite = true;

    for (int i = 0; i < NumFinalPolys; )
    {
        RendererPolygon* rp = &PolygonList[i];

        if (rp->PolyData->IsShadowMask) { i++; continue; }
        if (rp->PolyData->Translucent) { i++; continue; }

        if (rp->PolyData->Attr & (1<<14))
            S.DepthFunc = MTLCompareFunctionLessEqual;
        else
            S.DepthFunc = MTLCompareFunctionLess;

        u32 polyattr = rp->PolyData->Attr;
        u32 polyid = (polyattr >> 24) & 0x3F;

        StencilFunc(S, MTLCompareFunctionAlways, polyid, 0xFF);
        StencilOp(S, KEEP, KEEP, REPLACE);
        S.StencilWriteMask = 0xFF;

        i += RenderPolygonBatch(i);
    }

    S.Blend = true;
    S.BlendAlpha = (GPU3D.RenderDispCnt & (1<<3)) != 0;

    if (NumOpaqueFinalPolys > -1)
    {
        // pass 2: if needed, render translucent pixels that are against background pixels
        // when background alpha is zero, those need to be rendered with blending disabled

        if ((GPU3D.RenderClearAttr1 & 0x001F0000) == 0)
        {
            S.Blend = false;

            for (int i = 0; i < NumFinalPolys; )
            {
                RendererPolygon* rp = &PolygonList[i];

                if (rp->PolyData->IsShadowMask)
                {
                    // draw actual shadow mask

                    S.RenderMode = RenderMode_ShadowMask;

                    S.Blend = false;
                    S.ColorMask0 = false;
                    ColorMask1(S, false, false, false);
                    S.DepthWrite = false;

                    // render where stencil is 0xFF
                    // set to 0xFE where this polygon z-fails
                    S.DepthFunc = MTLCompareFunctionLess;
                    StencilFunc(S, MTLCompareFunctionEqual, 0xFF, 0xFF);
                    StencilOp(S, KEEP, INVERT, KEEP);
                    S.StencilWriteMask = 0x01;

                    i += RenderPolygonBatch(i);
                }
                else if (rp->PolyData->Translucent)
                {
                    bool needopaque = ((rp->PolyData->Attr & 0x001F0000) == 0x001F0000);

                    u32 polyattr = rp->PolyData->Attr;
                    u32 polyid = (polyattr >> 24) & 0x3F;

                    if (polyattr & (1<<14))
                        S.DepthFunc = MTLCompareFunctionLessEqual;
                    else
                        S.DepthFunc = MTLCompareFunctionLess;

                    if (needopaque)
                    {
                        S.RenderMode = RenderMode_Opaque;

                        S.Blend = false;
                        S.ColorMask0 = true;
                        ColorMask1(S, true, true, fogenable);

                        // set stencil to the polygon's ID
                        StencilFunc(S, MTLCompareFunctionAlways, polyid, 0xFF);
                        StencilOp(S, KEEP, KEEP, REPLACE);
                        S.StencilWriteMask = 0xFF;

                        S.DepthWrite = true;

                        RenderSinglePolygon(i);
                    }

                    S.RenderMode = RenderMode_Translucent;

                    bool transfog;
                    if (!(polyattr & (1<<15))) transfog = fogenable;
                    else                       transfog = false;

                    if (rp->PolyData->IsShadow)
                    {
                        // shadow against clear-plane will only pass if its polyID matches that of the clear plane
                        u32 clrpolyid = (GPU3D.RenderClearAttr1 >> 24) & 0x3F;
                        if (polyid != clrpolyid) { i++; continue; }

                        S.Blend = true;
                        S.ColorMask0 = true;
                        ColorMask1(S, false, false, transfog);

                        // draw where shadow mask has previously been rendered (stencil=0xFE)
                        // when passing, set it to (polyID | 0x40)
                        // TODO might break bit0 of polyID
                        StencilFunc(S, MTLCompareFunctionEqual, 0xFE, 0xFF);
                        StencilOp(S, KEEP, KEEP, INVERT);
                        S.StencilWriteMask = ~(0x40|polyid); // heheh

                        S.DepthWrite = (polyattr & (1<<11)) != 0;

                        i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                    }
                    else
                    {
                        S.ColorMask0 = true;
                        ColorMask1(S, false, false, transfog);

                        // draw on either background (0xFF) or shadowmask (0xFE)
                        // when passing, set it to (polyID | 0x40)
                        StencilFunc(S, MTLCompareFunctionEqual, 0xFF, 0xFE);
                        StencilOp(S, KEEP, KEEP, INVERT);
                        S.StencilWriteMask = ~(0x40|polyid); // heheh

                        S.DepthWrite = (polyattr & (1<<11)) != 0;

                        i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                    }
                }
                else
                    i++;
            }

            S.Blend = true;
            S.StencilWriteMask = 0xFF;
        }

        // pass 3: translucent pixels

        for (int i = 0; i < NumFinalPolys; )
        {
            RendererPolygon* rp = &PolygonList[i];

            if (rp->PolyData->IsShadowMask)
            {
                // clear shadow bits in stencil buffer
                // DuoDS: GL은 glClear(GL_STENCIL_BUFFER_BIT)를 마스크 0x80으로 — Metal은 패스 중간에 지울 수 없어 화면 가득 그린다

                S.StencilWriteMask = 0x80;
                [O->Enc setRenderPipelineState:O->StencilClearPipe];
                [O->Enc setDepthStencilState:O->DepthState(M.Device, MTLCompareFunctionAlways, false, MTLCompareFunctionAlways,
                                                           0xFF, 0x80, KEEP, KEEP, REPLACE)];
                [O->Enc setStencilReferenceValue:0];
                [O->Enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

                // draw actual shadow mask

                S.RenderMode = RenderMode_ShadowMask;

                S.Blend = false;
                S.ColorMask0 = false;
                ColorMask1(S, false, false, false);
                S.DepthWrite = false;

                // set stencil bit7 where the shadowmask z-fails
                S.DepthFunc = MTLCompareFunctionLess;
                StencilFunc(S, MTLCompareFunctionAlways, 0x80, 0x80);
                StencilOp(S, KEEP, REPLACE, KEEP);

                i += RenderPolygonBatch(i);
            }
            else if (rp->PolyData->Translucent)
            {
                bool needopaque = ((rp->PolyData->Attr & 0x001F0000) == 0x001F0000);

                u32 polyattr = rp->PolyData->Attr;
                u32 polyid = (polyattr >> 24) & 0x3F;

                if (polyattr & (1<<14))
                    S.DepthFunc = MTLCompareFunctionLessEqual;
                else
                    S.DepthFunc = MTLCompareFunctionLess;

                if (needopaque)
                {
                    S.RenderMode = RenderMode_Opaque;

                    S.Blend = false;
                    S.ColorMask0 = true;
                    ColorMask1(S, true, true, fogenable);

                    // set stencil to polyID
                    StencilFunc(S, MTLCompareFunctionAlways, polyid, 0xFF);
                    StencilOp(S, KEEP, KEEP, REPLACE);
                    S.StencilWriteMask = 0xFF;

                    S.DepthWrite = true;

                    RenderSinglePolygon(i);
                }

                S.RenderMode = RenderMode_Translucent;

                bool transfog;
                if (!(polyattr & (1<<15))) transfog = fogenable;
                else                       transfog = false;

                if (rp->PolyData->IsShadow)
                {
                    S.Blend = false;
                    S.ColorMask0 = false;
                    ColorMask1(S, false, false, false);
                    S.DepthWrite = false;

                    // render where polyID matches (ignoring other bits)
                    // clear bit7 where it passes
                    StencilFunc(S, MTLCompareFunctionEqual, polyid, 0x3F);
                    StencilOp(S, KEEP, KEEP, ZERO);
                    S.StencilWriteMask = 0x80;

                    RenderSinglePolygon(i);

                    S.Blend = true;
                    S.ColorMask0 = true;
                    ColorMask1(S, false, false, transfog);

                    // render where bit7 is set (ie. shadow mask)
                    // set bit6 and replace polyID
                    StencilFunc(S, MTLCompareFunctionEqual, 0xC0|polyid, 0x80);
                    StencilOp(S, KEEP, KEEP, REPLACE);
                    S.StencilWriteMask = 0x7F;

                    S.DepthWrite = (polyattr & (1<<11)) != 0;

                    i += RenderSinglePolygon(i);
                }
                else
                {
                    S.Blend = true;
                    S.ColorMask0 = true;
                    ColorMask1(S, false, false, transfog);

                    // render where polyID and bit6 do not match
                    // set bit6 and set polyID
                    StencilFunc(S, MTLCompareFunctionNotEqual, 0x40|polyid, 0x7F);
                    StencilOp(S, KEEP, KEEP, REPLACE);
                    S.StencilWriteMask = 0x7F;

                    S.DepthWrite = (polyattr & (1<<11)) != 0;

                    i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                }
            }
            else
                i++;
        }
    }
}

#undef DRAW

void MetalRenderer3D::RenderFrame()
{
    if (!O || !O->Color) return;
    WaitIdle();   // 버퍼 · 텍스처를 고쳐 쓰기 전에 지난 그리기가 끝나야 한다

    u8 clrBitmapDirty;
    if (!Texcache->Update(clrBitmapDirty) && GPU3D.RenderFrameIdentical && HasOutput)
    {
        return;
    }

    // if we're using a clear bitmap, set that up
    ClearBitmapDirty |= clrBitmapDirty;
    if (GPU3D.RenderDispCnt & (1<<14))
    {
        if (ClearBitmapDirty & (1<<0))
        {
            u16* vram = (u16*)&GPU.VRAMFlat_Texture[0x40000];
            for (int i = 0; i < 256*256; i++)
            {
                u16 color = vram[i];
                u32 r = (color << 1) & 0x3E; if (r) r++;
                u32 g = (color >> 4) & 0x3E; if (g) g++;
                u32 b = (color >> 9) & 0x3E; if (b) b++;
                u32 a = (color & 0x8000) ? 31 : 0;

                ClearBitmap[0][i] = r | (g << 8) | (b << 16) | (a << 24);
            }

            [O->ClearBitmapTex[0] replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0
                                      withBytes:ClearBitmap[0] bytesPerRow:256 * 4];
        }

        if (ClearBitmapDirty & (1<<1))
        {
            u16* vram = (u16*)&GPU.VRAMFlat_Texture[0x60000];
            for (int i = 0; i < 256*256; i++)
            {
                u16 val = vram[i];
                u32 depth = ((val & 0x7FFF) * 0x200) + 0x1FF;
                u32 fog = (val & 0x8000) << 9;

                ClearBitmap[1][i] = depth | fog;
            }

            [O->ClearBitmapTex[1] replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0
                                      withBytes:ClearBitmap[1] bytesPerRow:256 * 4];
        }

        ClearBitmapDirty = 0;
    }

    TexEnable = !!(GPU3D.RenderDispCnt & (1<<0));

    Config3D& cfg = O->Config;
    cfg.ScreenSize[0] = ScreenW;
    cfg.ScreenSize[1] = ScreenH;
    cfg.DispCnt = GPU3D.RenderDispCnt;
    cfg.AlphaRef = GPU3D.RenderAlphaRef;
    cfg.EdgeOffset = ScaleFactor;
    cfg.ClearPolyID = (GPU3D.RenderClearAttr1 >> 24) & 0x3F;
    cfg.ClearDepth = (((GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF) / 16777216.0f;

    for (int i = 0; i < 32; i++)
    {
        u16 c = GPU3D.RenderToonTable[i];
        u32 r = c & 0x1F;
        u32 g = (c >> 5) & 0x1F;
        u32 b = (c >> 10) & 0x1F;

        cfg.ToonColors[i][0] = (float)r / 31.0;
        cfg.ToonColors[i][1] = (float)g / 31.0;
        cfg.ToonColors[i][2] = (float)b / 31.0;
    }

    for (int i = 0; i < 8; i++)
    {
        u16 c = GPU3D.RenderEdgeTable[i];
        u32 r = c & 0x1F;
        u32 g = (c >> 5) & 0x1F;
        u32 b = (c >> 10) & 0x1F;

        cfg.EdgeColors[i][0] = (float)r / 31.0;
        cfg.EdgeColors[i][1] = (float)g / 31.0;
        cfg.EdgeColors[i][2] = (float)b / 31.0;
    }

    u32 fogR, fogG, fogB, fogA;
    {
        u32 c = GPU3D.RenderFogColor;
        fogR = c & 0x1F;
        fogG = (c >> 5) & 0x1F;
        fogB = (c >> 10) & 0x1F;
        fogA = (c >> 16) & 0x1F;

        cfg.FogColor[0] = (float)fogR / 31.0;
        cfg.FogColor[1] = (float)fogG / 31.0;
        cfg.FogColor[2] = (float)fogB / 31.0;
        cfg.FogColor[3] = (float)fogA / 31.0;
    }

    for (int i = 0; i < 34; i++)
    {
        u8 d = GPU3D.RenderFogDensityTable[i];
        cfg.FogDensity[i][0] = (float)d / 127.0;
    }

    cfg.FogOffset = GPU3D.RenderFogOffset;
    cfg.FogShift = GPU3D.RenderFogShift;

    id<MTLCommandBuffer> cmd = [M.Queue commandBuffer];

    // clear buffers
    // TODO: check whether 'clear polygon ID' affects translucent polyID
    // (for example when alpha is 1..30)
    // DuoDS: 평평한 지우기는 GL이 화면 가득 그리던 것을 패스의 지우기 값으로 — 결과는 같다
    bool bitmapClear = (GPU3D.RenderDispCnt & (1<<14)) != 0;
    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = O->Color;
    rpd.colorAttachments[1].texture = O->Attr;
    rpd.depthAttachment.texture = O->Depth;
    rpd.stencilAttachment.texture = O->Depth;
    for (int i = 0; i < 2; i++) rpd.colorAttachments[i].storeAction = MTLStoreActionStore;
    rpd.depthAttachment.storeAction = MTLStoreActionStore;
    rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    if (!bitmapClear)
    {
        u32 r = GPU3D.RenderClearAttr1 & 0x1F;
        u32 g = (GPU3D.RenderClearAttr1 >> 5) & 0x1F;
        u32 b = (GPU3D.RenderClearAttr1 >> 10) & 0x1F;
        u32 fog = (GPU3D.RenderClearAttr1 >> 15) & 0x1;
        u32 a = (GPU3D.RenderClearAttr1 >> 16) & 0x1F;
        u32 polyid = (GPU3D.RenderClearAttr1 >> 24) & 0x3F;
        u32 z = ((GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;

        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        // DuoDS: 5비트 → 6비트를 소프트웨어 렌더러와 같게(0이 아니면 ×2+1) — GL 렌더러는 이 줄이 주석이라 조금 어두웠다
        auto c6 = [](u32 v) { return v ? (v * 2 + 1) / 63.0 : 0.0; };
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(c6(r), c6(g), c6(b), a / 31.0);
        rpd.colorAttachments[1].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[1].clearColor = MTLClearColorMake(polyid / 63.0, 0, fog, 1);
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.clearDepth = z / 16777216.0;
        rpd.stencilAttachment.loadAction = MTLLoadActionClear;
        rpd.stencilAttachment.clearStencil = 0xFF;
    }
    else
    {
        for (int i = 0; i < 2; i++) rpd.colorAttachments[i].loadAction = MTLLoadActionDontCare;
        rpd.depthAttachment.loadAction = MTLLoadActionDontCare;
        rpd.stencilAttachment.loadAction = MTLLoadActionDontCare;
    }

    O->Enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [O->Enc setVertexBuffer:O->VertexBuf offset:0 atIndex:0];
    [O->Enc setFragmentBuffer:O->EdgeMaskBuf offset:0 atIndex:2];
    [O->Enc setVertexBytes:&cfg length:sizeof(cfg) atIndex:1];
    [O->Enc setFragmentBytes:&cfg length:sizeof(cfg) atIndex:0];

    if (bitmapClear)
    {
        // clear bitmap
        ClearBitmapU u {};
        u8 xoff = (GPU3D.RenderClearAttr2 >> 16) & 0xFF;
        u8 yoff = (GPU3D.RenderClearAttr2 >> 24) & 0xFF;
        u.Offset[0] = (float)xoff / 256.0;
        u.Offset[1] = (float)yoff / 256.0;
        u.ScreenSize[0] = ScreenW;
        u.ScreenSize[1] = ScreenH;
        u.PolyID = (GPU3D.RenderClearAttr1 >> 24) & 0x3F;

        [O->Enc setRenderPipelineState:O->ClearBitmapPipe];
        [O->Enc setDepthStencilState:O->DepthState(M.Device, MTLCompareFunctionAlways, true, MTLCompareFunctionAlways,
                                                   0xFF, 0xFF, REPLACE, REPLACE, REPLACE)];
        [O->Enc setStencilReferenceValue:0xFF];
        [O->Enc setFragmentTexture:O->ClearBitmapTex[0] atIndex:0];
        [O->Enc setFragmentTexture:O->ClearBitmapTex[1] atIndex:1];
        [O->Enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [O->Enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [O->Enc setFragmentBytes:&cfg length:sizeof(cfg) atIndex:0];
    }

    // GL: 지운 뒤의 상태
    S = GLState();
    S.Blend = false;
    S.ColorMask0 = true;
    ColorMask1(S, true, true, true);
    S.DepthWrite = true;
    S.StencilWriteMask = 0xFF;
    S.DepthFunc = MTLCompareFunctionAlways;
    StencilFunc(S, MTLCompareFunctionAlways, 0xFF, 0xFF);
    StencilOp(S, REPLACE, REPLACE, REPLACE);

    bool drewPolys = false;
    if (GPU3D.RenderNumPolygons)
    {
        int npolys = 0;
        int firsttrans = -1;
        for (u32 i = 0; i < GPU3D.RenderNumPolygons; i++)
        {
            if (GPU3D.RenderPolygonRAM[i]->Degenerate) continue;

            SetupPolygon(&PolygonList[npolys], GPU3D.RenderPolygonRAM[i]);
            if (firsttrans < 0 && GPU3D.RenderPolygonRAM[i]->Translucent)
                firsttrans = npolys;

            npolys++;
        }
        NumFinalPolys = npolys;
        NumOpaqueFinalPolys = firsttrans;

        BuildPolygons(&PolygonList[0], npolys);

        RenderSceneChunk();
        drewPolys = true;
    }
    [O->Enc endEncoding];
    O->Enc = nil;

    if (drewPolys && (GPU3D.RenderDispCnt & 0x00A0)) // fog/edge enabled
    {
        // DuoDS: 깊이 · 속성 버퍼를 읽어야 해서 따로 패스(색만)
        MTLRenderPassDescriptor* fp = [MTLRenderPassDescriptor renderPassDescriptor];
        fp.colorAttachments[0].texture = O->Color;
        fp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        fp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:fp];
        [enc setFragmentTexture:O->Depth atIndex:0];
        [enc setFragmentTexture:O->Attr atIndex:1];
        [enc setFragmentBytes:&cfg length:sizeof(cfg) atIndex:0];

        if (GPU3D.RenderDispCnt & (1<<5))
        {
            // edge marking
            // TODO: depth/polyid values at screen edges
            [enc setRenderPipelineState:O->EdgePipe];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }

        if (GPU3D.RenderDispCnt & (1<<7))
        {
            // fog
            [enc setRenderPipelineState:O->FogPipe[(GPU3D.RenderDispCnt & (1<<6)) ? 1 : 0]];
            [enc setBlendColorRed:fogR / 31.0 green:fogG / 31.0 blue:fogB / 31.0 alpha:fogA / 31.0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [enc endEncoding];
    }

    // 1×로 되읽기(2D 합성 · 화면 캡처)
    id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
    [ce setComputePipelineState:O->DownsamplePipe];
    [ce setTexture:O->Color atIndex:0];
    [ce setBuffer:O->Out1x offset:0 atIndex:0];
    u32 scale = ScaleFactor;
    [ce setBytes:&scale length:sizeof(scale) atIndex:1];
    NSUInteger tw = O->DownsamplePipe.threadExecutionWidth;
    NSUInteger th = O->DownsamplePipe.maxTotalThreadsPerThreadgroup / tw;
    [ce dispatchThreadgroups:MTLSizeMake((256 + tw - 1) / tw, (192 + th - 1) / th, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [ce endEncoding];

    [cmd commit];
    O->LastCmd = cmd;
    Pending = true;
    HasOutput = true;
}

u32* MetalRenderer3D::GetLine(int line)
{
    if (GPU3D.AbortFrame || !HasOutput || !O)
    {
        // TODO this isn't accurate
        memset(ScrolledLine, 0, sizeof(ScrolledLine));
        return ScrolledLine;
    }

    if (Pending) WaitIdle();

    u32* rawline = (u32*)O->Out1x.contents + line * 256;
    u16 xpos = GPU3D.RenderXPos;
    if (xpos == 0)
        return rawline;

    // apply X scroll

    if (xpos & 0x100)
    {
        int i = 0, j = xpos;
        for (; j < 512; i++, j++)
            ScrolledLine[i] = 0;
        for (j = 0; i < 256; i++, j++)
            ScrolledLine[i] = rawline[j];
    }
    else
    {
        int i = 0, j = xpos;
        for (; j < 256; i++, j++)
            ScrolledLine[i] = rawline[j];
        for (; i < 256; i++)
            ScrolledLine[i] = 0;
    }

    return ScrolledLine;
}

#undef S

}
