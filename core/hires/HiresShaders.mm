// HiresShaders.mm — 높은 해상도 렌더러의 Metal 셰이더(실행할 때 컴파일)와 장치 준비.
// 3D 셰이더는 melonDS OpenGL_shaders/3D*.glsl을 옮긴 것이다. 바뀐 곳은 "DuoDS:"로 표시.

#include "HiresMetal.h"

namespace melonDS
{

bool HiresMetal::Init(std::string& err)
{
    Device = MTLCreateSystemDefaultDevice();
    if (!Device) { err = "Metal 장치가 없음"; return false; }
    Queue = [Device newCommandQueue];
    NSError* e = nil;
    // 무게중심 좌표 · 프리미티브 번호가 되면 폴리곤 가장자리 표시를 DS처럼(HIRES_BARY) — 안 되면 근사로 다시 컴파일
    Bary = false;
    if ([Device supportsShaderBarycentricCoordinates])
    {
        MTLCompileOptions* opt = [MTLCompileOptions new];
        opt.preprocessorMacros = @{ @"HIRES_BARY": @1 };
        Library = [Device newLibraryWithSource:@(kHiresShaderSource) options:opt error:&e];
        Bary = Library != nil;
    }
    if (!Library) Library = [Device newLibraryWithSource:@(kHiresShaderSource) options:nil error:&e];
    if (!Library)
    {
        err = std::string("셰이더 컴파일 실패: ") + (e ? e.localizedDescription.UTF8String : "?");
        return false;
    }

    MTLTextureDescriptor* d = [MTLTextureDescriptor new];
    d.textureType = MTLTextureType2DArray;
    d.pixelFormat = MTLPixelFormatRGBA8Uint;
    d.width = 1;
    d.height = 1;
    d.arrayLength = 1;
    d.usage = MTLTextureUsageShaderRead;
    Textures.assign(1, [Device newTextureWithDescriptor:d]);
    FreeHandles.clear();
    return true;
}

id<MTLFunction> HiresMetal::Function(const char* name, std::string& err, MTLFunctionConstantValues* constants)
{
    NSError* e = nil;
    id<MTLFunction> f = constants ? [Library newFunctionWithName:@(name) constantValues:constants error:&e]
                                  : [Library newFunctionWithName:@(name)];
    if (!f) err = std::string("셰이더 함수 없음: ") + name + (e ? std::string(" — ") + e.localizedDescription.UTF8String : "");
    return f;
}

const char* const kHiresShaderSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

#ifndef HIRES_BARY
#define HIRES_BARY 0
#endif

// ── 3D 설정(GL의 uConfig — std140과 같은 배치) ──
struct Config3D
{
    float2 ScreenSize;
    uint DispCnt;
    uint AlphaRef;          // DuoDS: 알파 테스트(GL 렌더러엔 없던 것)
    float4 ToonColors[32];
    float4 EdgeColors[8];
    float4 FogColor;
    float4 FogDensity[34];  // .x만 씀
    uint FogOffset;
    uint FogShift;
    uint EdgeOffset;        // DuoDS: 가장자리 표시가 보는 이웃 거리(= 배율, DS 1픽셀 두께)
    uint ClearPolyID;       // DuoDS: 화면 밖 이웃은 지우기 면(소프트웨어 렌더러와 같게)
    float ClearDepth;
    uint Pad[3];
};

constant bool kWBuffer [[function_constant(0)]];

// ── 폴리곤(3DRenderVS/FS) ──
// 정점 7개 u32: XY · ZW(16비트씩) · RGBA(8비트) · ST(16비트) · 폴리곤 속성 · 텍스처 층 · 텍스처 크기(+ 반복 4비트 — DuoDS)
struct PolyOut
{
    float4 Pos [[position]];
    float4 Color;
    float2 Texcoord;            // DuoDS: 텍셀 단위(GL은 0~1) — 정수 텍스처를 직접 읽고 반복은 셰이더에서
    int3 Attr [[flat]];
    float Z;
};

vertex PolyOut poly_vs(uint vid [[vertex_id]], device const uint* vb [[buffer(0)]], constant Config3D& cfg [[buffer(1)]])
{
    device const uint* v = vb + vid * 7;
    uint4 p = uint4(v[0] & 0xFFFF, v[0] >> 16, v[1] & 0xFFFF, v[1] >> 16);
    uint4 c = uint4(v[2] & 0xFF, (v[2] >> 8) & 0xFF, (v[2] >> 16) & 0xFF, v[2] >> 24);
    int2 st = int2(short(v[3] & 0xFFFF), short(v[3] >> 16));
    int attr = int(v[4]);
    uint zshift = uint(attr >> 16) & 0x1F;

    PolyOut o;
    float4 fpos;
    fpos.xy = (float2(p.xy) * 2.0) / cfg.ScreenSize - 1.0;
    fpos.y = -fpos.y;                                   // DuoDS: Metal은 텍스처 첫 줄이 위
    float z = float(p.z << zshift) / 16777216.0;        // DuoDS: Metal 깊이는 0~1(GL은 -1~1)
    o.Z = z;
    fpos.z = kWBuffer ? 0.0 : z;
    fpos.w = float(p.w) / 65536.0;
    fpos.xyz *= fpos.w;
    o.Pos = fpos;
    o.Color = float4(c) / float4(255.0, 255.0, 255.0, 31.0);
    o.Texcoord = float2(st) / 16.0;
    o.Attr = int3(attr, int(v[5] & 0xFFFF), int(v[6]));
    return o;
}

static int wrap_texel(int c, int size, bool repeat, bool mirror)
{
    if (!repeat) return clamp(c, 0, size - 1);
    if (!mirror) return c & (size - 1);
    int m = c & (2 * size - 1);
    return m >= size ? 2 * size - 1 - m : m;
}

static float4 poly_color(PolyOut in, constant Config3D& cfg, texture2d_array<uint, access::read> tex)
{
    float4 col;
    float4 vcol = in.Color;
    int blendmode = (in.Attr.x >> 4) & 0x3;

    if (blendmode == 2)
    {
        if ((cfg.DispCnt & (1u << 1)) == 0)
            vcol.rgb = cfg.ToonColors[int(vcol.r * 31)].rgb;   // 툰
        else
            vcol.rgb = vcol.rrr;                                // 하이라이트
    }

    if (in.Attr.y == 0xFFFF)
    {
        col = vcol;   // 텍스처 없음
    }
    else
    {
        int tw = in.Attr.z & 0x7FF, th = (in.Attr.z >> 16) & 0x7FF, rep = (in.Attr.z >> 12) & 0xF;
        int2 t = int2(floor(in.Texcoord));
        t.x = wrap_texel(t.x, tw, rep & 1, rep & 4);
        t.y = wrap_texel(t.y, th, rep & 2, rep & 8);
        float4 tcol = float4(tex.read(uint2(t), uint(in.Attr.y))) / float4(63, 63, 63, 31);

        if ((blendmode & 1) != 0)
        {
            col.rgb = (tcol.rgb * tcol.a) + (vcol.rgb * (1.0 - tcol.a));   // 데칼
            col.a = vcol.a;
        }
        else
        {
            col = vcol * tcol;   // 곱하기
        }
    }

    if (blendmode == 2 && (cfg.DispCnt & (1u << 1)) != 0)
        col.rgb = min(col.rgb + cfg.ToonColors[int(vcol.r * 31)].rgb, 1.0);

    return col;
}

// DuoDS: 가장자리 표시 대상 — DS는 폴리곤의 기하 가장자리 픽셀만 표시한다(텍스처가 투명한 곳의 윤곽은 아님).
// 삼각형마다 폴리곤 가장자리인 변(사각형을 나눈 대각선은 아님)을 비트로 받아, 그 변에서 DS 1픽셀(= 배율 텍셀) 안이면 1.
// 무게중심 좌표를 못 쓰는 장치면 불투명 픽셀 모두(근사 — 투명 텍셀 윤곽에도 선이 생긴다)
static float edge_flag(float3 b, uint m, constant Config3D& cfg)
{
    if (m & 0x80) return 1.0;   // 선 폴리곤
    float3 d = b / max(fwidth(b), float3(1e-6));
    float dist = 1e9;
    if (m & 1) dist = min(dist, d.x);
    if (m & 2) dist = min(dist, d.y);
    if (m & 4) dist = min(dist, d.z);
    return dist < float(cfg.EdgeOffset) ? 1.0 : 0.0;
}

#if HIRES_BARY
#define EDGE_ARGS , float3 bary [[barycentric_coord, center_no_perspective]], uint prim [[primitive_id]], \
                  device const uchar* edgeMask [[buffer(2)]], constant uint2& edgeBase [[buffer(3)]]
#define EDGE_FLAG edge_flag(bary, edgeMask[edgeBase.x + prim * edgeBase.y], cfg)
#else
#define EDGE_ARGS
#define EDGE_FLAG 1.0
#endif

// mode: 0 불투명 · 1 반투명 · 2 그림자 틀. false = 버림
static bool poly_shade(PolyOut in, constant Config3D& cfg, texture2d_array<uint, access::read> tex, int mode, float edge,
                       thread float4& color, thread float4& attr)
{
    if (mode == 2)
    {
        color = float4(0, 0, 0, 1);
        attr = float4(0, 0, 0, 1);
        return true;
    }
    float4 col = poly_color(in, cfg, tex);
    if (int(col.a * 31.0 + 0.5) <= int(cfg.AlphaRef)) return false;   // DuoDS: 알파 테스트(꺼져 있으면 기준 0)
    if (mode == 0)
    {
        if (col.a < 30.5 / 31) return false;
        // R: 불투명 폴리곤 ID(가장자리 표시) · G: 가장자리 표시 대상(DuoDS — GL은 늘 0이라 표시가 안 됐다) · B: 안개
        attr = float4(float((in.Attr.x >> 24) & 0x3F) / 63.0, edge, float((in.Attr.x >> 15) & 0x1), 1);
    }
    else
    {
        if (col.a < 0.5 / 31) return false;
        if (col.a >= 30.5 / 31) return false;
        attr = float4(0, 0, 0, 1);
    }
    color = col;
    return true;
}

struct PolyFragZ
{
    float4 Color [[color(0)]];
    float4 Attr [[color(1)]];
};

struct PolyFragW
{
    float4 Color [[color(0)]];
    float4 Attr [[color(1)]];
    float Depth [[depth(any)]];
};

fragment PolyFragZ poly_fs_z(PolyOut in [[stage_in]], constant Config3D& cfg [[buffer(0)]], constant int& mode [[buffer(1)]],
                             texture2d_array<uint, access::read> tex [[texture(0)]] EDGE_ARGS)
{
    PolyFragZ o;
    float edge = EDGE_FLAG;
    if (!poly_shade(in, cfg, tex, mode, edge, o.Color, o.Attr)) discard_fragment();
    return o;
}

fragment PolyFragW poly_fs_w(PolyOut in [[stage_in]], constant Config3D& cfg [[buffer(0)]], constant int& mode [[buffer(1)]],
                             texture2d_array<uint, access::read> tex [[texture(0)]] EDGE_ARGS)
{
    PolyFragW o;
    float edge = EDGE_FLAG;
    if (!poly_shade(in, cfg, tex, mode, edge, o.Color, o.Attr)) discard_fragment();
    o.Depth = in.Z;
    return o;
}

// ── 화면 가득한 삼각형 하나 ──
struct QuadOut
{
    float4 Pos [[position]];
};

vertex QuadOut quad_vs(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    QuadOut o;
    o.Pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// 스텐실만 고칠 때(GL의 glClear(GL_STENCIL_BUFFER_BIT) — 색은 안 씀)
fragment float4 nothing_fs()
{
    return float4(0);
}

// ── 비트맵 지우기(3DClearBitmapVS/FS) ──
struct ClearBitmapU
{
    float2 Offset;
    float2 ScreenSize;
    uint PolyID;
    uint Pad[3];
};

struct ClearFrag
{
    float4 Color [[color(0)]];
    float4 Attr [[color(1)]];
    float Depth [[depth(any)]];
};

fragment ClearFrag clear_bitmap_fs(QuadOut in [[stage_in]], texture2d<uint, access::read> bmpColor [[texture(0)]],
                                   texture2d<uint, access::read> bmpDepth [[texture(1)]], constant ClearBitmapU& u [[buffer(0)]])
{
    float2 pos = in.Pos.xy / u.ScreenSize * float2(1.0, 0.75) + u.Offset;   // GL: (vPosition + 1) * (0.5, 0.375)
    uint2 t = uint2(int2(floor(pos * 256.0)) & 255);                       // GL_REPEAT
    uint4 c = bmpColor.read(t);
    uint depth = bmpDepth.read(t).r;
    ClearFrag o;
    o.Color = float4(c) / float4(63, 63, 63, 31);
    o.Attr = float4(float(u.PolyID) / 63.0, 0, float(depth >> 24), 1);
    o.Depth = float(depth & 0xFFFFFF) / 16777216.0;
    return o;
}

// ── 가장자리 표시(3DFinalPassEdgeFS) ──
fragment float4 edge_fs(QuadOut in [[stage_in]], depth2d<float, access::read> depthBuf [[texture(0)]],
                        texture2d<float, access::read> attrBuf [[texture(1)]], constant Config3D& cfg [[buffer(0)]])
{
    int2 coord = int2(in.Pos.xy);
    int2 last = int2(attrBuf.get_width(), attrBuf.get_height()) - 1;
    float4 attr = attrBuf.read(uint2(coord));
    if (attr.g == 0) return float4(0);

    float depth = depthBuf.read(uint2(coord));
    int polyid = int(attr.r * 63.0 + 0.5);   // DuoDS: 반올림(GL은 잘라서 1 작게 나오는 때가 있다)
    int s = int(cfg.EdgeOffset);
    int2 nb[4] = { int2(0, -s), int2(0, s), int2(-s, 0), int2(s, 0) };
    for (int k = 0; k < 4; k++)
    {
        // DuoDS: 화면 밖 이웃은 지우기 면(melonDS 소프트웨어 렌더러가 테두리를 그렇게 채운다 — 화면 끝에 선이 생김)
        int2 q = coord + nb[k];
        int npoly;
        float ndepth;
        if (any(q < 0) || any(q > last))
        {
            npoly = int(cfg.ClearPolyID);
            ndepth = cfg.ClearDepth;
        }
        else
        {
            npoly = int(attrBuf.read(uint2(q)).r * 63.0 + 0.5);
            ndepth = depthBuf.read(uint2(q));
        }
        if (npoly != polyid && depth < ndepth)
        {
            float4 ret;
            ret.rgb = cfg.EdgeColors[polyid >> 3].rgb;
            ret.a = (cfg.DispCnt & (1u << 4)) != 0 ? 0.5 : 1.0;   // 정확하진 않음(GL과 같음)
            return ret;
        }
    }
    return float4(0);
}

// ── 안개(3DFinalPassFogFS) ──
fragment float4 fog_fs(QuadOut in [[stage_in]], depth2d<float, access::read> depthBuf [[texture(0)]],
                       texture2d<float, access::read> attrBuf [[texture(1)]], constant Config3D& cfg [[buffer(0)]])
{
    uint2 coord = uint2(in.Pos.xy);
    float4 attr = attrBuf.read(coord);
    if (attr.b == 0) return float4(0);

    int idepth = int(depthBuf.read(coord) * 16777216.0);
    int densityid, densityfrac;
    if (idepth < int(cfg.FogOffset))
    {
        densityid = 0;
        densityfrac = 0;
    }
    else
    {
        uint udepth = uint(idepth) - cfg.FogOffset;
        udepth = (udepth >> 2) << cfg.FogShift;
        densityid = int(udepth >> 17);
        if (densityid >= 32)
        {
            densityid = 32;
            densityfrac = 0;
        }
        else
            densityfrac = int(udepth & 0x1FFFFu);
    }
    float density = mix(cfg.FogDensity[densityid].x, cfg.FogDensity[densityid + 1].x, float(densityfrac) / 131072.0);
    return float4(density);
}

// ── 1×로 되읽기: 블록 가운데 텍셀 → 소프트웨어 렌더러 형식(6비트 RGB · 5비트 알파) ──
// 2D 합성(3D가 덮이는지)과 화면 캡처가 이걸 쓴다
kernel void downsample_3d(texture2d<float, access::read> color [[texture(0)]], device uint* out [[buffer(0)]],
                          constant uint& scale [[buffer(1)]], uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= 256 || gid.y >= 192) return;
    float4 c = color.read(gid * scale + scale / 2);
    uint r = uint(c.r * 63.0 + 0.5), g = uint(c.g * 63.0 + 0.5), b = uint(c.b * 63.0 + 0.5), a = uint(c.a * 31.0 + 0.5);
    out[gid.y * 256 + gid.x] = r | (g << 8) | (b << 16) | (a << 24);
}

// ── 합성: 1× 2D 결과 + 고해상도 3D ──
// ctrl(픽셀마다, DuoRenderer2D가 남김): 0~17 다른 색(6비트 × 3) · 18~22 eva/evy · 23~27 evb · 28~30 방식 · 31 대신 1× 결과
//   방식 1: 3D가 맨 위 · 2: 3D 알파로 밑과 섞음 · 3/4: 밝게/어둡게 · 5: 3D 위의 반투명 층과 섞음 · 0: 3D 없음(1× 그대로)
// lines(줄마다): 0~15 마스터 밝기(MASTER_BRIGHT) · 16~24 3D X 스크롤
static int3 bright_up(int3 c, int f, int bias) { return c + ((((63 - c) * f) + bias) >> 4); }
static int3 bright_down(int3 c, int f, int bias) { return c - (((c * f) + bias) >> 4); }

kernel void compose(texture2d<float, access::read> c3d [[texture(0)]], texture2d<float, access::read> fb [[texture(1)]],
                    texture2d<float, access::write> out [[texture(2)]], device const uint* ctrl [[buffer(0)]],
                    device const uint* lines [[buffer(1)]], constant uint& scale [[buffer(2)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    uint2 p = gid / scale;
    uint c = ctrl[p.y * 256 + p.x];
    uint mode = (c >> 28) & 0x7;
    if (mode == 0)
    {
        out.write(fb.read(p), gid);
        return;
    }

    uint li = lines[p.y];
    int xpos = int((li >> 16) & 0x1FF);
    if (xpos & 0x100) xpos -= 512;
    int x3 = int(gid.x) + xpos * int(scale);
    float4 t = (x3 >= 0 && x3 < int(c3d.get_width())) ? c3d.read(uint2(x3, gid.y)) : float4(0);
    int a3 = int(t.a * 31.0 + 0.5);
    int3 col3 = int3(t.rgb * 63.0 + 0.5);
    int3 other = int3(c & 0x3F, (c >> 6) & 0x3F, (c >> 12) & 0x3F);
    int ev1 = int((c >> 18) & 0x1F), ev2 = int((c >> 23) & 0x1F);

    int3 res;
    if (a3 == 0)
    {
        // 이 텍셀엔 3D가 없다 — 1×에서도 없던 자리면 1× 결과 그대로, 있던 자리(가장자리)면 3D 밑의 층
        if ((c >> 31) != 0 || mode == 5)
        {
            out.write(fb.read(p), gid);
            return;
        }
        res = other;
    }
    else if (mode == 1) res = col3;
    else if (mode == 2)
    {
        int eva = a3 + 1, evb = 32 - eva;   // ColorBlend5
        res = eva == 32 ? col3 : min((col3 * eva + other * evb + 0x10) >> 5, 63);
    }
    else if (mode == 3) res = bright_up(col3, ev1, 0x8);
    else if (mode == 4) res = bright_down(col3, ev1, 0x7);
    else res = min((other * ev1 + col3 * ev2 + 0x8) >> 4, 63);   // ColorBlend4(위 층, 3D)

    uint mb = li & 0xFFFF;
    int factor = min(int(mb & 0x1F), 16);
    if ((mb >> 14) == 1) res = bright_up(res, factor, 0x0);
    else if ((mb >> 14) == 2) res = bright_down(res, factor, 0xF);

    float3 o = float3((res << 2) | (res >> 4)) / 255.0;   // 6비트 → 8비트(ExpandColor)
    out.write(float4(o, 1.0), gid);
}
)MSL";

}
