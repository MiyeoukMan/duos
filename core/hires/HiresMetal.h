// HiresMetal.h — 높은 해상도 렌더러(DuoRenderer · MetalRenderer3D)가 같이 쓰는 Metal 객체. Objective-C++ 파일에서만.
// 3D 그리기와 합성이 같은 명령 큐에 들어가므로 GPU에서 넣은 순서대로 돈다(따로 기다릴 것은 CPU가 결과를 읽을 때뿐).

#pragma once

#import <Metal/Metal.h>

#include <string>
#include <vector>

#include "types.h"

namespace melonDS
{

struct HiresMetal
{
    id<MTLDevice> Device = nil;
    id<MTLCommandQueue> Queue = nil;
    id<MTLLibrary> Library = nil;
    bool Bary = false;   // 셰이더가 무게중심 좌표로 폴리곤 가장자리를 안다(HIRES_BARY)

    // 텍스처 캐시의 손잡이(번호) → 텍스처 배열. 0번은 "텍스처 없음"(1×1 빈 배열 — 묶을 자리를 비워 두지 않게)
    std::vector<id<MTLTexture>> Textures;
    std::vector<u32> FreeHandles;

    // 실패하면 err에 이유
    bool Init(std::string& err);
    id<MTLFunction> Function(const char* name, std::string& err, MTLFunctionConstantValues* constants = nil);
};

// 셰이더 원본(HiresShaders.mm) — 실행할 때 컴파일한다(빌드 맥에 Metal 툴체인이 없어도 되게)
extern const char* const kHiresShaderSource;

}
