// Metal3D.h — melonDS의 OpenGL 3D 렌더러(GPU3D_OpenGL.cpp)를 Metal로 옮긴 것. 3D를 배율(×1~4)대로 높은 해상도에 그린다.
// 결과: 고해상도 색 텍스처(DuoRenderer의 합성 패스가 읽음) + 1×로 되읽은 줄(GetLine — 2D 합성 · 화면 캡처용).

#pragma once

#include <memory>

#include "GPU3D.h"
#include "GPU3D_Texcache.h"

namespace melonDS
{

struct HiresMetal;

// 텍스처 캐시(GPU3D_Texcache.h의 틀)가 텍스처를 만들고 올리는 곳. 손잡이 = HiresMetal::Textures 번호
class TexcacheMetalLoader
{
public:
    explicit TexcacheMetalLoader(HiresMetal* metal) : M(metal) {}
    u32 GenerateTexture(u32 width, u32 height, u32 layers);
    void UploadTexture(u32 handle, u32 width, u32 height, u32 layer, void* data);
    void DeleteTexture(u32 handle);

private:
    HiresMetal* M;
};

using TexcacheMetal = Texcache<TexcacheMetalLoader, u32>;

class MetalRenderer3D : public Renderer3D
{
public:
    MetalRenderer3D(melonDS::GPU3D& gpu3D, HiresMetal& metal);
    ~MetalRenderer3D() override;
    bool Init() override;
    void Reset() override;

    void SetScaleFactor(int scale);
    int GetScaleFactor() const { return ScaleFactor; }

    void RenderFrame() override;
    void RestartFrame() override { RenderFrame(); }
    u32* GetLine(int line) override;

    // 고해상도 색 텍스처(id<MTLTexture>) — 같은 명령 큐 뒤에 넣은 일은 이 프레임의 그림을 본다
    void* ColorTexture() const;
    // CPU가 결과를 읽기 전에 GPU가 끝내기를 기다린다
    void WaitIdle();

    const char* LastError() const { return Error.c_str(); }

private:
    struct RendererPolygon
    {
        Polygon* PolyData;

        u32 NumIndices;
        u32 IndicesOffset;
        bool Lines;

        u32 RenderKey;

        u32 TexID;
        u32 TexRepeat;
    };

    struct Objects;   // Metal 객체(.mm 안)

    HiresMetal& M;
    std::unique_ptr<Objects> O;
    std::string Error;

    RendererPolygon PolygonList[2048] {};
    int NumFinalPolys = 0, NumOpaqueFinalPolys = 0;

    bool TexEnable = false;
    std::unique_ptr<TexcacheMetal> Texcache;

    u32* ClearBitmap[2];
    u8 ClearBitmapDirty = 0x3;

    u32* VertexBuffer = nullptr;   // Metal 버퍼 내용(공유 메모리)
    u32* IndexBuffer = nullptr;
    u8* EdgeMask = nullptr;        // 색인 자리마다(삼각형의 첫 색인): 폴리곤 가장자리인 변 비트 — 셰이더가 읽는다
    u32 NumVertices = 0, NumIndices = 0;

    int ScaleFactor = 0;
    int ScreenW = 0, ScreenH = 0;

    bool Pending = false;          // 그린 결과를 아직 기다리지 않음
    bool HasOutput = false;
    alignas(8) u32 ScrolledLine[256];

    void SetupPolygon(RendererPolygon* rp, Polygon* polygon) const;
    u32* SetupVertex(const Polygon* poly, int vid, const Vertex* vtx, u32 vtxattr, u32 texlayer, u32* vptr) const;
    void BuildPolygons(RendererPolygon* polygons, int npolys);
    int RenderSinglePolygon(int i);
    int RenderPolygonBatch(int i);
    void RenderSceneChunk();
};

}
