// 시험 ROM — ARM9 쪽. 내가 직접 만든 검증용 프로그램(상용 코드 · 닌텐도 데이터 없음).
// 위 화면(엔진 A): 3D 삼각형 — 저절로 돈다, 십자키로 옮김, A/B/X/Y로 색, L/R로 도는 방향, SELECT로 바탕색, START로 처음 자리.
// 아래 화면(엔진 B, 16비트 비트맵): 위쪽 버튼 칸 12개(누르면 켜짐), 터치한 곳에 흰 점, 오른쪽 끝 마이크 세기 막대.
// ARM7(arm7.c)이 X · Y 버튼 · 터치 · 마이크를 읽어 SHARED에 적어 준다.
// -DSCENE3D(mkrom.py --scene3d)면 위 화면이 3D 시험 장면(scene3d_*): 원근 바둑판 바닥(직접 색 텍스처, 반복 · 뒤집기) ·
// 도는 사각형(4색 팔레트 텍스처, 0번 색 투명) · 반투명 삼각형(밑 2D와 알파 섞기) + 안개 · 가장자리 표시.
// SELECT를 누르는 동안 엔진 A를 아래 화면으로, START를 누르는 동안 W 버퍼.

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed short s16;
typedef signed int s32;

#define REG16(a) (*(volatile u16*)(a))
#define REG32(a) (*(volatile u32*)(a))

#define POWCNT1     REG32(0x04000304)
#define DISPCNT_A   REG32(0x04000000)
#define VCOUNT      REG16(0x04000006)
#define KEYINPUT    REG16(0x04000130)
#define VRAMCNT_C   (*(volatile u8*)0x04000242)
#define DISPCNT_B   REG32(0x04001000)
#define BG3CNT_B    REG16(0x0400100E)
#define BG3PA_B     REG16(0x04001030)
#define BG3PB_B     REG16(0x04001032)
#define BG3PC_B     REG16(0x04001034)
#define BG3PD_B     REG16(0x04001036)
#define BG3X_B      REG32(0x04001038)
#define BG3Y_B      REG32(0x0400103C)
#define BITMAP_B    ((volatile u16*)0x06200000)

#define DISP3DCNT   REG16(0x04000060)
#define CLEAR_COLOR REG32(0x04000350)
#define CLEAR_DEPTH REG16(0x04000354)
#define MTX_MODE    REG32(0x04000440)
#define MTX_IDENT   REG32(0x04000454)
#define GX_COLOR    REG32(0x04000480)
#define GX_VTX16    REG32(0x0400048C)
#define POLY_ATTR   REG32(0x040004A4)
#define BEGIN_VTXS  REG32(0x04000500)
#define END_VTXS    REG32(0x04000504)
#define SWAP_BUF    REG32(0x04000540)
#define VIEWPORT    REG32(0x04000580)

#define VRAMCNT_A   (*(volatile u8*)0x04000240)
#define VRAMCNT_E   (*(volatile u8*)0x04000244)
#define BLDCNT_A    REG16(0x04000050)
#define BG_PAL_A    ((volatile u16*)0x05000000)
#define EDGE_COLOR  ((volatile u16*)0x04000330)
#define FOG_COLOR   REG32(0x04000358)
#define FOG_OFFSET  REG16(0x0400035C)
#define FOG_TABLE   ((volatile u8*)0x04000360)
#define MTX_PUSH    REG32(0x04000444)
#define MTX_POP     REG32(0x04000448)
#define MTX_LOAD44  REG32(0x04000458)
#define MTX_MULT33  REG32(0x04000468)
#define MTX_TRANS   REG32(0x04000470)
#define GX_TEXCOORD REG32(0x04000488)
#define TEXIMAGE    REG32(0x040004A8)
#define TEXPLTT     REG32(0x040004AC)

struct Shared { volatile u32 frame7; volatile u16 keyxy; volatile u16 tx, ty; volatile u16 mic; };
#define SHARED ((struct Shared*)0x023F0000)

#define RGB(r, g, b) ((u16)((r) | ((g) << 5) | ((b) << 10)))

__attribute__((naked, section(".text.entry"))) void _start(void)
{
    __asm__ volatile("ldr sp, =0x02300000\n b main\n .ltorg\n");
}

// sin(a) — a는 0~1023이 한 바퀴, 결과는 4.12 고정 소수(±4096). 포물선 근사.
static s32 isin(s32 a)
{
    a &= 1023;
    s32 sign = 1;
    if (a >= 512) { a -= 512; sign = -1; }
    s32 x = a - 256;                         // -256 ~ 255, 꼭대기가 0
    s32 y = 4096 - (x * x) / 16;             // 256² / 16 = 4096
    return sign * y;
}

static void fill(int x0, int y0, int w, int h, u16 c)
{
    for (int y = y0; y < y0 + h; y++)
        for (int x = x0; x < x0 + w; x++)
            if (x >= 0 && x < 256 && y >= 0 && y < 192) BITMAP_B[y * 256 + x] = c | 0x8000;
}

static void vblank(void)
{
    while (VCOUNT >= 192) {}
    while (VCOUNT < 192) {}
}

static void vtx(s32 x, s32 y)
{
    GX_VTX16 = (u32)(x & 0xFFFF) | ((u32)(y & 0xFFFF) << 16);
    GX_VTX16 = 0;
}

#ifdef SCENE3D
static void vtx3(s32 x, s32 y, s32 z)
{
    GX_VTX16 = (u32)(x & 0xFFFF) | ((u32)(y & 0xFFFF) << 16);
    GX_VTX16 = (u32)(z & 0xFFFF);
}

static void texcoord(s32 s, s32 t)   // 텍셀 단위(×16 = 12.4 고정 소수)
{
    GX_TEXCOORD = (u32)((s * 16) & 0xFFFF) | ((u32)((t * 16) & 0xFFFF) << 16);
}

static void scene3d_init(void)
{
    // 텍스처: VRAM A(슬롯 0) — LCDC로 쓴 뒤 텍스처로. 0: 32×32 직접 색 바둑판(8텍셀 칸, (2,2)에 빨간 점)
    // 0x800: 16×16 4색(2비트) 둥근 무늬 — 0번 색은 투명
    VRAMCNT_A = 0x80;
    volatile u16* tex = (volatile u16*)0x06800000;
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++)
        {
            u16 c = ((x >> 3) ^ (y >> 3)) & 1 ? RGB(26, 22, 14) : RGB(9, 6, 4);
            if (x >= 2 && x < 4 && y >= 2 && y < 4) c = RGB(31, 2, 2);
            tex[y * 32 + x] = c | 0x8000;
        }
    volatile u16* tex2 = (volatile u16*)0x06800800;
    for (int y = 0; y < 16; y++)
    {
        u32 row = 0;
        for (int x = 0; x < 16; x++)
        {
            int dx = x * 2 - 15, dy = y * 2 - 15, d = dx * dx + dy * dy;
            u32 c = d > 225 ? 0 : d > 120 ? 1 : (((x + y) >> 2) & 1) ? 2 : 3;
            row |= c << (x * 2);
        }
        tex2[y * 2] = row & 0xFFFF;
        tex2[y * 2 + 1] = row >> 16;
    }
    VRAMCNT_A = 0x83;
    // 텍스처 팔레트: VRAM E(LCDC 0x06880000에 쓴 뒤 팔레트 슬롯으로)
    VRAMCNT_E = 0x80;
    volatile u16* pal = (volatile u16*)0x06880000;
    pal[0] = 0; pal[1] = RGB(31, 31, 31); pal[2] = RGB(4, 18, 31); pal[3] = RGB(31, 20, 2);
    VRAMCNT_E = 0x83;

    BG_PAL_A[0] = RGB(8, 12, 22);           // 2D 바탕(3D 뒤 — 지우기 알파 0)
    BLDCNT_A = 0x2000;                      // 반투명 3D가 2D 바탕과 섞인다
    EDGE_COLOR[0] = RGB(2, 14, 4);          // 폴리곤 ID 0~7(바닥)
    EDGE_COLOR[1] = RGB(31, 4, 4);          // 8~15(도는 사각형)
    FOG_COLOR = RGB(8, 12, 22) | (31u << 16);
    FOG_OFFSET = 0x7000;                    // 바닥 깊이는 0x40C0(앞) ~ 0x7A70(끝) — 뒤쪽 절반에 안개
    for (int i = 0; i < 32; i++) FOG_TABLE[i] = i * 4;
    DISP3DCNT = 0x01 | 0x08 | 0x20 | 0x80 | (4 << 8);   // 텍스처 · 알파 섞기 · 가장자리 · 안개(밀도 단계 4)
    CLEAR_COLOR = RGB(0, 0, 0) | (0u << 16) | (63u << 24);  // 투명, 폴리곤 ID 63

    // 원근 투영(세로 60°, 4:3, 가까이 0.5 · 멀리 40)
    MTX_MODE = 0;
    static const s32 proj[16] = { 5321, 0, 0, 0,  0, 7094, 0, 0,  0, 0, -4200, -4096,  0, 0, -4148, 0 };
    for (int i = 0; i < 16; i++) MTX_LOAD44 = (u32)proj[i];
    MTX_MODE = 2;
    MTX_IDENT = 0;
}

static void scene3d_draw(s32 angle, u32 keys)
{
    MTX_IDENT = 0;

    // 바닥: y = -1, x ±4, z -1 ~ -9 — 텍스처 8번 반복(S는 뒤집으며)
    MTX_PUSH = 0;
    MTX_TRANS = 0; MTX_TRANS = (u32)-4096; MTX_TRANS = (u32)(-5 * 4096);
    POLY_ATTR = 0x001F00C0 | (1u << 15) | (0u << 24);
    TEXIMAGE = (0 >> 3) | (1u << 16) | (1u << 17) | (1u << 18) | (2u << 20) | (2u << 23) | (7u << 26);
    GX_COLOR = RGB(31, 31, 31);
    BEGIN_VTXS = 1;   // 사각형
    texcoord(0, 0);     vtx3(-4 * 4096, 0, -4 * 4096);
    texcoord(0, 256);   vtx3(-4 * 4096, 0, 4 * 4096);
    texcoord(256, 256); vtx3(4 * 4096, 0, 4 * 4096);
    texcoord(256, 0);   vtx3(4 * 4096, 0, -4 * 4096);
    END_VTXS = 0;
    MTX_POP = 1;

    // 도는 사각형: z = -3.2, Y축으로 돈다, 4색 텍스처(0번 투명)
    MTX_PUSH = 0;
    MTX_TRANS = (u32)(-3 * 1024); MTX_TRANS = (u32)(1 * 1024); MTX_TRANS = (u32)(-13 * 1024);
    s32 c = isin(angle + 256), sn = isin(angle);
    MTX_MULT33 = (u32)c; MTX_MULT33 = 0; MTX_MULT33 = (u32)-sn;
    MTX_MULT33 = 0; MTX_MULT33 = 4096; MTX_MULT33 = 0;
    MTX_MULT33 = (u32)sn; MTX_MULT33 = 0; MTX_MULT33 = (u32)c;
    POLY_ATTR = 0x001F00C0 | (1u << 15) | (8u << 24);
    TEXPLTT = 0;
    TEXIMAGE = (0x800 >> 3) | (1u << 20) | (1u << 23) | (2u << 26) | (1u << 29);
    BEGIN_VTXS = 1;
    texcoord(0, 0);   vtx3(-2458, 2458, 0);
    texcoord(0, 16);  vtx3(-2458, -2458, 0);
    texcoord(16, 16); vtx3(2458, -2458, 0);
    texcoord(16, 0);  vtx3(2458, 2458, 0);
    END_VTXS = 0;
    MTX_POP = 1;

    // 반투명 삼각형(알파 12, ID 20): 앞쪽, 사각형 · 바닥 · 바탕에 걸친다
    POLY_ATTR = 0x000C00C0 | (20u << 24);
    TEXIMAGE = 0;
    GX_COLOR = RGB(6, 14, 31);
    BEGIN_VTXS = 0;
    vtx3(-1 * 4096, 2 * 4096, -5 * 4096);
    vtx3(2 * 4096, -1 * 4096, -4 * 4096);
    vtx3(4 * 4096, 3 * 4096, -6 * 4096);
    END_VTXS = 0;

    SWAP_BUF = (keys & (1 << 3)) ? 2 : 0;   // START: W 버퍼
}
#endif

void main(void)
{
    POWCNT1 = 0x820F;                        // LCD · 2D A · 3D · 2D B, 엔진 A를 위 화면에
    DISPCNT_A = 0x10108;                     // 그래픽 표시, BG0 = 3D
    VRAMCNT_C = 0x84;                        // VRAM C → 엔진 B 배경
    DISPCNT_B = 0x10000 | 5 | (1 << 11);     // 모드 5, BG3
    BG3CNT_B = 0x4084;                       // 256 × 256 16비트 비트맵
    BG3PA_B = 256; BG3PB_B = 0; BG3PC_B = 0; BG3PD_B = 256;
    BG3X_B = 0; BG3Y_B = 0;

    fill(0, 0, 256, 192, RGB(3, 3, 5));
    for (int x = 0; x < 256; x += 16) fill(x, 24, 1, 168, RGB(5, 5, 8));
    for (int y = 24; y < 192; y += 16) fill(0, y, 256, 1, RGB(5, 5, 8));

    DISP3DCNT = 0;
    CLEAR_DEPTH = 0x7FFF;
    VIEWPORT = 0 | (0 << 8) | (255u << 16) | (191u << 24);
    MTX_MODE = 0; MTX_IDENT = 0;
    MTX_MODE = 2; MTX_IDENT = 0;
#ifdef SCENE3D
    scene3d_init();
#endif

    s32 angle = 0, spin = 6, px = 0, py = 0;
    for (;;)
    {
        u16 k = ~KEYINPUT & 0x3FF;
        u16 xy = ~SHARED->keyxy;
        u32 keys = k | ((xy & 1) << 10) | ((xy & 2) << 10);   // 비트 10 X, 11 Y
        int pen = (xy & 0x40) != 0;

        if (keys & (1 << 4)) px += 48;
        if (keys & (1 << 5)) px -= 48;
        if (keys & (1 << 6)) py += 48;
        if (keys & (1 << 7)) py -= 48;
        if (keys & (1 << 8)) spin = 12;
        if (keys & (1 << 9)) spin = -12;
        if (keys & (1 << 3)) { px = 0; py = 0; angle = 0; spin = 6; }
        angle += spin;

#ifdef SCENE3D
        (void)px; (void)py; (void)vtx;
        POWCNT1 = (keys & (1 << 2)) ? 0x020F : 0x820F;   // SELECT: 엔진 A(3D)를 아래 화면에
        scene3d_draw(angle, keys);
#else

        u16 col = RGB(31, 24, 4);
        if (keys & (1 << 0)) col = RGB(31, 4, 4);
        if (keys & (1 << 1)) col = RGB(4, 31, 4);
        if (keys & (1 << 10)) col = RGB(4, 8, 31);
        if (keys & (1 << 11)) col = RGB(31, 4, 31);
        CLEAR_COLOR = (keys & (1 << 2) ? RGB(2, 10, 6) : RGB(2, 3, 9)) | (31u << 16);

        // 삼각형: 반지름 0.6, 세 꼭짓점을 120°씩
        POLY_ATTR = 0x001F00C0;
        BEGIN_VTXS = 0;
        for (int i = 0; i < 3; i++)
        {
            s32 a = angle + i * 341;
            s32 x = px + isin(a + 256) * 2458 / 4096;
            s32 y = py + isin(a) * 2458 / 4096 * 4 / 3;
            GX_COLOR = i == 0 ? RGB(31, 31, 31) : col;
            vtx(x, y);
        }
        END_VTXS = 0;
        SWAP_BUF = 0;
#endif

        // 버튼 칸: A B SEL START → ← ↑ ↓ R L X Y
        for (int i = 0; i < 12; i++)
            fill(4 + i * 21, 4, 18, 14, (keys >> i) & 1 ? RGB(31, 26, 6) : RGB(8, 8, 12));
        if (pen) fill(SHARED->tx - 1, SHARED->ty - 1, 3, 3, RGB(31, 31, 31));
        int m = SHARED->mic * 160 / 2048;
        if (m > 160) m = 160;
        fill(250, 28, 5, 160 - m, RGB(4, 4, 6));
        fill(250, 188 - m, 5, m, RGB(6, 31, 12));
        // 뚜껑: ARM7이 옮겨 준 KEYXY 비트 7(1 = 닫힘) — 닫혀 있으면 오른쪽 아래 구석이 빨강
        fill(238, 180, 8, 8, (SHARED->keyxy & 0x80) ? RGB(31, 4, 4) : RGB(8, 8, 12));

        vblank();
    }
}
