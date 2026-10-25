// DuoRenderer.h — 3D만 높은 해상도(×2~4)로 그리는 melonDS 렌더러(DuoDS).
//
// 2D(배경 · 스프라이트 · 합성 · 화면 캡처)는 melonDS 소프트웨어 렌더러와 같은 코드로 256×192에 그린다
// (이 파일 = GPU_Soft.cpp, DuoRenderer2D = GPU2D_Soft.cpp의 사본). 3D는 Metal로 높은 해상도에 그리고(MetalRenderer3D),
// 1×로 되읽은 것을 2D 합성 · 캡처에 쓴다. 엔진 A는 픽셀마다 "3D가 어디에 어떻게 섞였나"를 남기고(Ctrl3D),
// VBlank 때 Metal 합성 패스가 그 표시대로 고해상도 3D를 끼워 그 화면의 고해상도 그림을 만든다.
// 3D가 없던 화면은 1× 그림(GetFramebuffers)만 — 앱은 그 화면을 원래 확대 방식으로 그린다.

#pragma once

#include <memory>
#include <string>
#include <vector>

#include "GPU.h"

namespace melonDS
{

class NDS;
struct HiresMetal;
class MetalRenderer3D;

class DuoRenderer : public Renderer
{
public:
    DuoRenderer(melonDS::NDS& nds, int scale);
    ~DuoRenderer() override;
    bool Init() override;
    void Reset() override;
    void Stop() override;

    void PostSavestate() override;

    void SetRenderSettings(RendererSettings& settings) override;

    void DrawScanline(u32 line) override;
    void DrawSprites(u32 line) override;

    void VBlank() override;
    void VBlankEnd() override {}

    void AllocCapture(u32 bank, u32 start, u32 len) override {}
    void SyncVRAMCapture(u32 bank, u32 start, u32 len, bool complete) override {}

    bool GetFramebuffers(void** top, void** bottom) override;
    void SwapBuffers() override;

    int GetScaleFactor() const { return ScaleFactor; }
    void SetScaleFactor(int scale);

    // 이번 프레임의 합성이 끝날 때까지 기다린다(프레임을 돌린 뒤 — 그래야 ScreenTexture가 다 그려진 것)
    void WaitFrame();
    // 화면(0 위 · 1 아래)의 고해상도 그림 — id<MTLTexture>(BGRA 8비트). 이 프레임에 그 화면에 3D가 없었으면 nullptr.
    // 다음다음 프레임까지 그대로 있다(3장을 돌려 쓴다).
    void* ScreenTexture(int screen, int* width, int* height) const;
    // 같은 것을 CPU로(시험 도구용). BGRA 메모리 = 0xAARRGGBB
    bool ReadScreen(int screen, std::vector<u32>& out, int& width, int& height) const;

    const char* LastError() const { return Error.c_str(); }

private:
    friend class DuoRenderer2D;

    struct Compose;   // 합성 패스의 Metal 객체(.mm 안)

    int ScaleFactor;
    std::string Error;
    std::unique_ptr<HiresMetal> Metal;
    std::unique_ptr<Compose> C;
    MetalRenderer3D* Rend3DMetal = nullptr;   // = Rend3D

    u32* Framebuffer[2][2];

    u32* Output3D;
    alignas(8) u32 Output2D[2][256];
    alignas(8) u32 Ctrl3D[256];   // 엔진 A가 이 줄에 남긴 3D 표시(DuoRenderer2D가 씀)

    void DrawScanlineA(u32 line, u32* dst);
    void DrawScanlineB(u32 line, u32* dst);

    void DoCapture(u32 line);

    void ApplyMasterBrightness(u16 regval, u32* dst);
    void ExpandColor(u32* dst);
};

}
