// 시험 ROM — ARM7 쪽. X · Y 버튼 · 펜(KEYXY), 터치 좌표(TSC), 마이크 세기를 읽어 SHARED에 적고,
// A를 누르는 동안 PSG 채널 8로 440Hz 네모파를 낸다.

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed int s32;

#define REG16(a) (*(volatile u16*)(a))
#define REG32(a) (*(volatile u32*)(a))

#define KEYINPUT  REG16(0x04000130)
#define KEYXY     REG16(0x04000136)
#define SPICNT    REG16(0x040001C0)
#define SPIDATA   REG16(0x040001C2)
#define POWCNT2   REG16(0x04000304)
#define SOUND8CNT REG32(0x04000480)
#define SOUND8TMR REG16(0x04000488)
#define SOUNDCNT  REG16(0x04000500)

struct Shared { volatile u32 frame7; volatile u16 keyxy; volatile u16 tx, ty; volatile u16 mic; };
#define SHARED ((struct Shared*)0x023F0000)

__attribute__((naked, section(".text.entry"))) void _start(void)
{
    __asm__ volatile("ldr sp, =0x0380FD00\n b main\n .ltorg\n");
}

static u8 spi(u8 v, int hold)
{
    while (SPICNT & 0x80) {}
    SPICNT = 0x8201 | (hold ? 0x0800 : 0);   // 켜기 · 터치스크린 · 2MHz
    SPIDATA = v;
    while (SPICNT & 0x80) {}
    return (u8)SPIDATA;
}

static u32 tsc(u8 cmd)
{
    spi(cmd, 1);
    u32 hi = spi(0, 1);
    u32 lo = spi(0, 0);
    return ((hi << 5) | (lo >> 3)) & 0xFFF;
}

void main(void)
{
    POWCNT2 = 1;
    SOUNDCNT = 0x8000 | 127;
    int playing = 0;
    s32 peak = 0;
    for (;;)
    {
        u16 xy = KEYXY;
        SHARED->keyxy = xy;
        if (!(xy & 0x40))
        {
            SHARED->tx = (u16)(tsc(0xD0) >> 4);
            SHARED->ty = (u16)(tsc(0x90) >> 4);
        }

        s32 s = (s32)tsc(0xE0) - 2048;
        if (s < 0) s = -s;
        if (s > peak) peak = s; else peak -= peak >> 6;
        SHARED->mic = (u16)peak;

        int a = !(KEYINPUT & 1);
        if (a && !playing)
        {
            SOUND8TMR = (u16)(0x10000 - 16756991 / (440 * 8));
            SOUND8CNT = 127 | (64u << 16) | (3u << 24) | (3u << 29) | (1u << 31);
        }
        else if (!a && playing)
        {
            SOUND8CNT = 0;
        }
        playing = a;
        SHARED->frame7++;
    }
}
