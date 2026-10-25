// DSCore.cpp — melonDS NDS 객체 하나를 감싼다(DSCore.h 참고).
// 바이오스는 melonDS에 들어 있는 FreeBIOS, 펌웨어는 그 자리에서 만든 것 → 게임은 바로 부팅(direct boot)한다.
// 닌텐도 바이오스 · 펌웨어 파일이 없어도 되고, 대신 DS 본체 메뉴는 없다.

#include "DSCore.h"

#include "NDS.h"
#include "NDSCart.h"
#include "GPU.h"
#include "GPU_Soft.h"
#include "SPU.h"
#include "SPI.h"
#include "SPI_Firmware.h"
#include "RTC.h"
#include "Savestate.h"
#include "Platform.h"
#include "frontend/mic_blow.h"
#include "MPInterface.h"
#include "LAN.h"
#include "hires/DuoRenderer.h"

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace melonDS;

struct DSCore
{
    std::unique_ptr<NDS> nds;
    std::string romPath;
    std::string savePath;

    // 게임이 쓴 세이브 — 에뮬레이션 스레드에서 쓰고, 1초 조용하면 파일로 낸다
    std::mutex saveLock;
    std::vector<u8> save;
    bool saveDirty = false;
    u64 saveDirtyAt = 0;

    std::atomic<u32> keys{0};
    std::atomic<u32> touch{0};     // 비트 31 = 누름, 아래는 x | y << 8
    // 한 프레임(16ms)보다 짧게 눌렀다 뗀 것도 한 프레임은 눌린 것으로 — 다음 프레임에서 비운다
    std::atomic<u32> keyLatch{0};
    std::atomic<u32> touchLatch{0};
    std::atomic<int> lidClosed{0};
    bool lidApplied = false;
    std::atomic<int> micBlow{0};
    int micPos = 0;

    bool running = false;

    std::atomic<int> scale3D{1};   // 바라는 3D 배율(아무 스레드)
    int scaleApplied = 1;          // 렌더러에 들어간 배율(에뮬레이션 스레드)

    DSFirmwareUser user{};
    std::string nickname = "Duo";
    bool hasMac = false;
    u8 mac[6] = {};
};

// ── Platform_Apple.cpp가 부르는 것 ───────────────────────

static void (*g_LogHandler)(int, const char*) = nullptr;
static std::string g_LocalDir = ".";

void DSCore_Log(int level, const char* text)
{
    if (g_LogHandler) g_LogHandler(level, text);
    else fputs(text, stderr);
}

const char* DSCore_LocalDir() { return g_LocalDir.c_str(); }

void DSCore_SignalStop(void* userdata, int reason)
{
    auto* c = static_cast<DSCore*>(userdata);
    if (c) c->running = false;
    char buf[64];
    snprintf(buf, sizeof(buf), "emulation stopped (reason %d)\n", reason);
    DSCore_Log(1, buf);
}

void DSCore_WriteNDSSave(void* userdata, const u8* data, u32 len, u32 offset, u32 writelen)
{
    auto* c = static_cast<DSCore*>(userdata);
    if (!c || c->savePath.empty()) return;
    std::lock_guard<std::mutex> lk(c->saveLock);
    if (c->save.size() != len)
    {
        c->save.assign(data, data + len);
    }
    else if (offset + writelen <= len)
    {
        memcpy(c->save.data() + offset, data + offset, writelen);
    }
    else
    {
        // 끝에서 처음으로 감기는 쓰기
        memcpy(c->save.data() + offset, data + offset, len - offset);
        memcpy(c->save.data(), data, writelen - (len - offset));
    }
    c->saveDirty = true;
    c->saveDirtyAt = Platform::GetMSCount();
}

int DSCore_MicRead(void* userdata, s16* data, int maxlength)
{
    auto* c = static_cast<DSCore*>(userdata);
    if (!c || !c->micBlow.load())
    {
        memset(data, 0, maxlength * sizeof(s16));
        return maxlength;
    }
    const int n = (int)(sizeof(mic_blow) / sizeof(mic_blow[0]));
    for (int i = 0; i < maxlength; i++)
    {
        data[i] = mic_blow[c->micPos++];
        if (c->micPos >= n) c->micPos = 0;
    }
    return maxlength;
}

// ── 안쪽 도우미 ─────────────────────────────────────────

static void SetErr(char* err, int errlen, const char* msg)
{
    if (err && errlen > 0) snprintf(err, errlen, "%s", msg);
}

static bool ReadWholeFile(const std::string& path, std::unique_ptr<u8[]>& out, u32& len)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseeko(f, 0, SEEK_END);
    off_t size = ftello(f);
    fseeko(f, 0, SEEK_SET);
    if (size <= 0 || size > 0x40000000) { fclose(f); return false; }
    out = std::make_unique<u8[]>((size_t)size);
    bool ok = fread(out.get(), 1, (size_t)size, f) == (size_t)size;
    fclose(f);
    len = (u32)size;
    return ok;
}

// UTF-8 → UTF-16(펌웨어 닉네임). BMP 밖 글자는 '?'.
static size_t Utf8To16(const std::string& s, char16_t* out, size_t max)
{
    size_t n = 0;
    for (size_t i = 0; i < s.size() && n < max;)
    {
        unsigned char c = (unsigned char)s[i];
        u32 cp;
        int extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c >> 5) == 6) { cp = c & 0x1F; extra = 1; }
        else if ((c >> 4) == 14) { cp = c & 0x0F; extra = 2; }
        else { cp = '?'; extra = (c >> 3) == 30 ? 3 : 0; }
        i++;
        for (int k = 0; k < extra && i < s.size(); k++, i++) cp = (cp << 6) | ((unsigned char)s[i] & 0x3F);
        out[n++] = cp > 0xFFFF ? u'?' : (char16_t)cp;
    }
    return n;
}

// ── Nintendo WFC 설정 — 펌웨어의 접속점(확장 3 + 보통 3). 게임이 처음 접속할 때 접속 ID를 만들어 여기 쓴다.
// 펌웨어는 켤 때마다 새로 만들므로 이 부분만 로컬 폴더에 남겨 되살린다(접속 ID가 바뀌면 서버 · 세이브의 친구 코드가 어긋난다).

constexpr u32 kWfcSize = 3 * (sizeof(Firmware::ExtendedWifiAccessPoint) + sizeof(Firmware::WifiAccessPoint));
constexpr u32 kWfcRegular = 3 * sizeof(Firmware::ExtendedWifiAccessPoint);   // 보통 접속점이 시작하는 곳

static std::string WfcPath() { return g_LocalDir + "/wfcsettings.bin"; }

static bool ReadWfc(u8* out)
{
    FILE* f = fopen(WfcPath().c_str(), "rb");
    if (!f) return false;
    bool ok = fread(out, 1, kWfcSize, f) == kWfcSize;
    fclose(f);
    return ok;
}

void DSCore_WriteFirmware(const Firmware& fw, u32 offset, u32 len)
{
    u32 start = fw.GetExtendedAccessPointOffset();
    if (offset + len <= start || offset >= start + kWfcSize) return;   // 접속 설정이 아닌 곳(본체 설정은 켤 때마다 앱에서)
    std::string path = WfcPath(), tmp = path + ".tmp";
    FILE* f = fopen(tmp.c_str(), "wb");
    if (!f) return;
    bool ok = fwrite(fw.GetExtendedAccessPointPosition(), 1, kWfcSize, f) == kWfcSize;
    ok = (fclose(f) == 0) && ok;
    if (ok) rename(tmp.c_str(), path.c_str());
    else remove(tmp.c_str());
    DSCore_Log(1, "Nintendo WFC 설정을 남김\n");
}

int ds_wfc_reset(void)
{
    return (remove(WfcPath().c_str()) == 0 || errno == ENOENT) ? 0 : -1;
}

int ds_wfc_configured(void)
{
    std::vector<u8> buf(kWfcSize);
    if (!ReadWfc(buf.data())) return 0;
    for (int i = 0; i < 3; i++)
    {
        Firmware::WifiAccessPoint ap;
        memcpy(ap.Bytes, &buf[kWfcRegular + i * sizeof(ap)], sizeof(ap));
        for (u8 b : ap.NintendoWFCID)
            if (b) return 1;
    }
    return 0;
}

static Firmware MakeFirmware(const DSCore* c)
{
    Firmware fw(0);
    auto& data = fw.GetEffectiveUserData();

    char16_t name[10] = {};
    size_t nlen = Utf8To16(c->nickname, name, 10);
    if (nlen > 0)
    {
        memset(data.Nickname, 0, sizeof(data.Nickname));
        memcpy(data.Nickname, name, nlen * sizeof(char16_t));
        data.NameLength = (u16)nlen;
    }

    int lang = c->user.language;
    if (lang >= DS_LANG_JAPANESE && lang <= DS_LANG_SPANISH)
    {
        data.Settings &= ~Firmware::Language::Reserved;
        data.Settings |= (u16)lang;
    }
    if (c->user.favorite_color >= 0 && c->user.favorite_color <= 15) data.FavoriteColor = (u8)c->user.favorite_color;
    if (c->user.birthday_month >= 1 && c->user.birthday_month <= 12) data.BirthdayMonth = (u8)c->user.birthday_month;
    if (c->user.birthday_day >= 1 && c->user.birthday_day <= 31) data.BirthdayDay = (u8)c->user.birthday_day;

    if (c->hasMac)
    {
        auto& header = fw.GetHeader();
        MacAddress mac;
        memcpy(mac.data(), c->mac, 6);
        mac[0] &= 0xFC;   // 방송 주소가 아니게
        header.MacAddr = mac;
        header.UpdateChecksum();
    }

    std::vector<u8> wfc(kWfcSize);
    if (ReadWfc(wfc.data()))
    {
        memcpy(fw.GetExtendedAccessPointPosition(), wfc.data(), kWfcSize);
        DSCore_Log(1, "Nintendo WFC 설정을 되살림\n");
    }

    fw.UpdateChecksums();
    return fw;
}

static void SyncClock(NDS& nds)
{
    time_t now = time(nullptr);
    struct tm t;
    localtime_r(&now, &t);
    nds.RTC.SetDateTime(t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec);
}

static DuoRenderer* Hires(DSCore* c)
{
    return c && c->nds ? dynamic_cast<DuoRenderer*>(&c->nds->GPU.GetRenderer()) : nullptr;
}

// 바라는 3D 배율로 렌더러를 바꾼다(프레임 사이에서만). 1 = 소프트웨어 렌더러(3D는 별도 스레드), 2~4 = DuoRenderer
static void ApplyScale(DSCore* c, bool restart)
{
    int want = c->scale3D.load();
    if (want == c->scaleApplied) return;
    NDS& nds = *c->nds;
    RendererSettings rs{};
    rs.ScaleFactor = want;
    rs.Threaded = true;
    if (want > 1)
    {
        if (DuoRenderer* duo = Hires(c))
        {
            duo->SetRenderSettings(rs);
        }
        else
        {
            nds.GPU.SetRenderer(std::make_unique<DuoRenderer>(nds, want));
            if (!Hires(c))
            {
                // Init이 실패하면 melonDS가 소프트웨어 렌더러로 바꿔 둔다
                DSCore_Log(1, "3D 고해상도를 켤 수 없음(Metal) — 1배로 그린다\n");
                rs.ScaleFactor = 1;
                nds.GetRenderer().SetRenderSettings(rs);
                want = 1;
                c->scale3D.store(1);
            }
        }
    }
    else
    {
        nds.GPU.SetRenderer(std::make_unique<SoftRenderer>(nds));
        nds.GetRenderer().SetRenderSettings(rs);
    }
    c->scaleApplied = want;
    // 새 렌더러는 이번 프레임의 3D를 아직 안 그렸다 — 지금 그린다(안 하면 한 프레임 3D가 빈다)
    if (restart) nds.GPU.Restart3DFrame();
}

static void ApplyInput(DSCore* c)
{
    NDS& nds = *c->nds;
    nds.SetKeyMask(~(c->keys.load() | c->keyLatch.exchange(0)) & 0xFFF);
    u32 t = c->touch.load();
    u32 tl = c->touchLatch.exchange(0);
    if (!(t & 0x80000000u) && (tl & 0x80000000u)) t = tl;
    if (t & 0x80000000u) nds.TouchScreen((u16)(t & 0xFF), (u16)((t >> 8) & 0xFF));
    else nds.ReleaseScreen();
    bool lid = c->lidClosed.load() != 0;
    if (lid != c->lidApplied)
    {
        nds.SetLidClosed(lid);
        c->lidApplied = lid;
    }
}

// ── 바깥 인터페이스 ──────────────────────────────────────

extern "C" {

void ds_set_log_handler(void (*handler)(int, const char*)) { g_LogHandler = handler; }
void ds_set_local_dir(const char* path) { g_LocalDir = path ? path : "."; }

DSCore* ds_create(void)
{
    auto* c = new DSCore();
    c->user.language = DS_LANG_ENGLISH;
    c->user.favorite_color = 11;
    c->user.birthday_month = 1;
    c->user.birthday_day = 1;
    return c;
}

void ds_destroy(DSCore* core)
{
    if (!core) return;
    ds_flush_save(core);
    if (core->nds) core->nds->Stop();
    core->nds.reset();
    delete core;
}

void ds_set_firmware_user(DSCore* core, const DSFirmwareUser* user)
{
    if (!core || !user) return;
    core->user = *user;
    core->nickname = user->nickname ? user->nickname : "";
    core->user.nickname = nullptr;
}

int ds_load_rom(DSCore* core, const char* rom_path, const char* save_path, char* err, int errlen)
{
    if (!core || !rom_path) { SetErr(err, errlen, "no ROM path"); return -1; }

    // 앞의 게임을 정리
    ds_flush_save(core);
    if (core->nds) core->nds->Stop();
    core->nds.reset();
    core->running = false;

    std::unique_ptr<u8[]> rom;
    u32 romLen = 0;
    if (!ReadWholeFile(rom_path, rom, romLen) || romLen < 0x200)
    {
        SetErr(err, errlen, "ROM 파일을 읽을 수 없습니다.");
        return -2;
    }

    core->romPath = rom_path;
    core->savePath = save_path ? save_path : "";
    {
        std::lock_guard<std::mutex> lk(core->saveLock);
        core->save.clear();
        core->saveDirty = false;
    }

    NDSCart::NDSCartArgs cartArgs{};
    if (!core->savePath.empty())
    {
        std::unique_ptr<u8[]> sram;
        u32 sramLen = 0;
        if (ReadWholeFile(core->savePath, sram, sramLen))
        {
            std::lock_guard<std::mutex> lk(core->saveLock);
            core->save.assign(sram.get(), sram.get() + sramLen);
            cartArgs.SRAM = std::move(sram);
            cartArgs.SRAMLength = sramLen;
        }
    }

    auto cart = NDSCart::ParseROM(std::move(rom), romLen, core, std::move(cartArgs));
    if (!cart)
    {
        SetErr(err, errlen, "DS ROM이 아니거나 망가진 파일입니다.");
        return -3;
    }

    NDSArgs args{};
    args.Firmware = MakeFirmware(core);
    args.JIT = std::nullopt;                 // iOS는 실행 중 코드 생성을 막는다 — 인터프리터로 돈다
    args.Interpolation = AudioInterpolation::Cubic;
    args.OutputSampleRate = DS_AUDIO_RATE;

    core->nds = std::make_unique<NDS>(std::move(args), core);
    NDS& nds = *core->nds;

    RendererSettings rs{};
    rs.ScaleFactor = 1;
    rs.Threaded = true;    // 3D를 따로 도는 스레드에서 그린다
    nds.GetRenderer().SetRenderSettings(rs);
    core->scaleApplied = 1;
    ApplyScale(core, false);

    nds.Reset();
    nds.SetNDSCart(std::move(cart));
    nds.Reset();
    std::string name = core->romPath.substr(core->romPath.find_last_of('/') + 1);
    nds.SetupDirectBoot(name);
    nds.SPI.GetPowerMan()->SetBatteryLevelOkay(true);
    SyncClock(nds);
    core->lidApplied = false;
    nds.Start();
    core->running = true;
    return 0;
}

void ds_reset(DSCore* core)
{
    if (!core || !core->nds) return;
    ds_flush_save(core);
    NDS& nds = *core->nds;
    nds.Reset();
    std::string name = core->romPath.substr(core->romPath.find_last_of('/') + 1);
    nds.SetupDirectBoot(name);
    SyncClock(nds);
    core->lidApplied = false;
    nds.Start();
    core->running = true;
}

int ds_is_running(DSCore* core) { return core && core->nds && core->running ? 1 : 0; }

void ds_set_keys(DSCore* core, uint32_t pressed)
{
    if (!core) return;
    core->keys.store(pressed & 0xFFF);
    core->keyLatch.fetch_or(pressed & 0xFFF);
}

void ds_set_touch(DSCore* core, int touching, int x, int y)
{
    if (!core) return;
    if (!touching) { core->touch.store(0); return; }
    if (x < 0) x = 0; if (x > 255) x = 255;
    if (y < 0) y = 0; if (y > 191) y = 191;
    u32 v = 0x80000000u | (u32)x | ((u32)y << 8);
    core->touch.store(v);
    core->touchLatch.store(v);
}

void ds_set_lid_closed(DSCore* core, int closed) { if (core) core->lidClosed.store(closed ? 1 : 0); }

void ds_set_mac(DSCore* core, const uint8_t mac[6])
{
    if (!core || !mac) return;
    memcpy(core->mac, mac, 6);
    core->hasMac = true;
}
void ds_set_mic_blow(DSCore* core, int blowing) { if (core) core->micBlow.store(blowing ? 1 : 0); }

void ds_run_frame(DSCore* core)
{
    if (!core || !core->nds || !core->running) return;
    ApplyScale(core, true);
    ApplyInput(core);
    core->nds->RunFrame();
    if (DuoRenderer* duo = Hires(core)) duo->WaitFrame();   // 고해상도 합성이 끝나야 ds_screen_texture가 다 그려진 것

    bool flush = false;
    {
        std::lock_guard<std::mutex> lk(core->saveLock);
        flush = core->saveDirty && Platform::GetMSCount() - core->saveDirtyAt > 1000;
    }
    if (flush) ds_flush_save(core);
}

const uint32_t* ds_screen(DSCore* core, int bottom)
{
    if (!core || !core->nds) return nullptr;
    void* top = nullptr;
    void* bot = nullptr;
    if (!core->nds->GPU.GetFramebuffers(&top, &bot)) return nullptr;
    return static_cast<const uint32_t*>(bottom ? bot : top);
}

void ds_set_3d_scale(DSCore* core, int scale)
{
    if (!core) return;
    core->scale3D.store(scale < 1 ? 1 : scale > 4 ? 4 : scale);
}

int ds_3d_scale(DSCore* core) { return core ? core->scaleApplied : 1; }

void* ds_screen_texture(DSCore* core, int bottom, int* width, int* height)
{
    DuoRenderer* duo = Hires(core);
    return duo ? duo->ScreenTexture(bottom ? 1 : 0, width, height) : nullptr;
}

int ds_screen_hires(DSCore* core, int bottom, uint32_t* out, int max_pixels, int* width, int* height)
{
    DuoRenderer* duo = Hires(core);
    std::vector<u32> px;
    int w = 0, h = 0;
    if (!duo || !duo->ReadScreen(bottom ? 1 : 0, px, w, h) || (int)px.size() > max_pixels) return 0;
    memcpy(out, px.data(), px.size() * 4);
    if (width) *width = w;
    if (height) *height = h;
    return (int)px.size();
}

int ds_read_audio(DSCore* core, int16_t* out, int max_frames)
{
    if (!core || !core->nds) return 0;
    return core->nds->SPU.ReadOutput(out, max_frames);
}

int ds_flush_save(DSCore* core)
{
    if (!core) return 0;
    std::vector<u8> copy;
    std::string path;
    {
        std::lock_guard<std::mutex> lk(core->saveLock);
        if (!core->saveDirty || core->savePath.empty()) return 0;
        copy = core->save;
        path = core->savePath;
        core->saveDirty = false;
    }
    // 새 파일에 다 쓴 다음 바꿔 끼운다 — 쓰다가 꺼져도 옛 세이브는 남는다
    std::string tmp = path + ".tmp";
    FILE* f = fopen(tmp.c_str(), "wb");
    if (!f) return 0;
    bool ok = fwrite(copy.data(), 1, copy.size(), f) == copy.size();
    ok = fclose(f) == 0 && ok;
    if (!ok || rename(tmp.c_str(), path.c_str()) != 0)
    {
        remove(tmp.c_str());
        std::lock_guard<std::mutex> lk(core->saveLock);
        core->saveDirty = true;
        return 0;
    }
    return 1;
}

int ds_save_state(DSCore* core, const char* path)
{
    if (!core || !core->nds || !path) return -1;
    Savestate state;
    if (state.Error) return -2;
    core->nds->DoSavestate(&state);
    if (state.Error) return -3;
    std::string tmp = std::string(path) + ".tmp";
    FILE* f = fopen(tmp.c_str(), "wb");
    if (!f) return -4;
    bool ok = fwrite(state.Buffer(), 1, state.Length(), f) == state.Length();
    ok = fclose(f) == 0 && ok;
    if (!ok || rename(tmp.c_str(), path) != 0) { remove(tmp.c_str()); return -5; }
    return 0;
}

int ds_load_state(DSCore* core, const char* path)
{
    if (!core || !core->nds || !path) return -1;
    std::unique_ptr<u8[]> buf;
    u32 len = 0;
    if (!ReadWholeFile(path, buf, len)) return -2;

    // 망가진 상태 파일이면 되돌릴 수 있게 지금 상태를 먼저 떠 둔다
    auto backup = std::make_unique<Savestate>(Savestate::DEFAULT_SIZE);
    if (backup->Error || !core->nds->DoSavestate(backup.get()) || backup->Error) return -3;

    Savestate state(buf.get(), len, false);
    if (!core->nds->DoSavestate(&state) || state.Error)
    {
        backup->Rewind(false);
        core->nds->DoSavestate(backup.get());
        return -4;
    }
    core->running = true;
    return 0;
}


// ── 근거리 무선 ──────────────────────────────────────

}   // extern "C"

static std::recursive_mutex g_LanLock;
static int g_LanState = DS_LAN_NONE;

std::recursive_mutex& DSCore_LanLock() { return g_LanLock; }

static LAN& Lan()
{
    if (MPInterface::GetType() != MPInterface_LAN) MPInterface::Set(MPInterface_LAN);
    return static_cast<LAN&>(MPInterface::Get());
}

extern "C" {

int ds_lan_host(const char* player, int max_players)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    LAN& lan = Lan();
    lan.EndSession();
    g_LanState = DS_LAN_NONE;
    if (max_players < 2) max_players = 2;
    if (max_players > 16) max_players = 16;
    if (!lan.StartHost(player ? player : "DuoDS", max_players)) return -1;
    g_LanState = DS_LAN_HOST;
    return 0;
}

int ds_lan_join(const char* player, const char* host)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    LAN& lan = Lan();
    lan.EndSession();
    g_LanState = DS_LAN_NONE;
    if (!host || !*host) return -1;
    if (!lan.StartClient(player ? player : "DuoDS", host)) return -2;
    g_LanState = DS_LAN_CLIENT;
    return 0;
}

void ds_lan_leave(void)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    if (MPInterface::GetType() == MPInterface_LAN) Lan().EndSession();
    g_LanState = DS_LAN_NONE;
}

int ds_lan_state(void)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    return g_LanState;
}

int ds_lan_players(DSLanPlayer* out, int max)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    if (g_LanState == DS_LAN_NONE) return 0;
    auto list = Lan().GetPlayerList();
    int n = 0;
    for (auto& p : list)
    {
        if (n >= max) break;
        DSLanPlayer& o = out[n++];
        o.id = p.ID;
        memcpy(o.name, p.Name, sizeof(o.name));
        o.name[31] = 0;
        o.status = (int)p.Status;
        o.address = p.Address;
        o.is_local = p.IsLocalPlayer ? 1 : 0;
        o.ping_ms = p.Ping;
    }
    return n;
}

int ds_lan_max_players(void)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    return g_LanState == DS_LAN_NONE ? 0 : Lan().GetMaxPlayers();
}

void ds_lan_process(void)
{
    std::lock_guard<std::recursive_mutex> lk(g_LanLock);
    if (g_LanState != DS_LAN_NONE) Lan().Process();
}

}
