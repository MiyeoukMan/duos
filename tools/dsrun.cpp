// dsrun — 화면 없이 DS ROM을 돌려 본다(macOS). 두 화면을 PNG로, 소리를 WAV로 남기고, 속도를 잰다.
//
//   dsrun <rom> [--frames N] [--png out.png] [--png-at F:out.png] [--wav out.wav] [--save game.sav]
//               [--press F1-F2:KEYS] [--touch F1-F2:X,Y] [--blow F1-F2] [--lid F1-F2] [--state-save F:path] [--state-load F:path] [--quiet]
//               [--scale N] [--scale-at F:N]
//
//   KEYS는 A B X Y L R START SELECT UP DOWN LEFT RIGHT를 + 로 잇는다(예: 100-110:START, 200-260:RIGHT+B).
//   PNG는 위 화면 위에 아래 화면을 쌓은 256 × 384. --scale N(2~4 — 3D 내부 해상도)이면 (256 × N) × (384 × N):
//   3D가 있던 화면은 고해상도 그림, 아닌 화면은 1× 그림을 N배로(가장 가까운 픽셀).

#include "DSCore.h"

#include <zlib.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct Press { int from, to; uint32_t keys; };
struct Touch { int from, to, x, y; };
struct Blow { int from, to; };
struct Lid { int from, to; };   // 그 프레임들 동안 뚜껑을 닫는다
struct Shot { int frame; std::string path; };
struct StateOp { int frame; std::string path; bool save; };
struct ScaleOp { int frame, scale; };

static uint32_t ParseKeys(const std::string& s)
{
    static const struct { const char* name; uint32_t bit; } table[] = {
        {"A", DS_KEY_A}, {"B", DS_KEY_B}, {"X", DS_KEY_X}, {"Y", DS_KEY_Y}, {"L", DS_KEY_L}, {"R", DS_KEY_R},
        {"START", DS_KEY_START}, {"SELECT", DS_KEY_SELECT}, {"UP", DS_KEY_UP}, {"DOWN", DS_KEY_DOWN},
        {"LEFT", DS_KEY_LEFT}, {"RIGHT", DS_KEY_RIGHT},
    };
    uint32_t keys = 0;
    size_t i = 0;
    while (i <= s.size())
    {
        size_t j = s.find('+', i);
        if (j == std::string::npos) j = s.size();
        std::string k = s.substr(i, j - i);
        bool found = false;
        for (auto& t : table) if (k == t.name) { keys |= t.bit; found = true; }
        if (!found && !k.empty()) { fprintf(stderr, "unknown key %s\n", k.c_str()); exit(2); }
        i = j + 1;
    }
    return keys;
}

static void ParseRange(const std::string& s, int& from, int& to, std::string& rest)
{
    size_t colon = s.find(':');
    std::string range = s.substr(0, colon);
    rest = colon == std::string::npos ? "" : s.substr(colon + 1);
    size_t dash = range.find('-');
    from = atoi(range.c_str());
    to = dash == std::string::npos ? from : atoi(range.c_str() + dash + 1);
}

static void Be32(std::vector<uint8_t>& v, uint32_t x)
{
    v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}

static void Chunk(FILE* f, const char* type, const std::vector<uint8_t>& data)
{
    std::vector<uint8_t> head;
    Be32(head, (uint32_t)data.size());
    fwrite(head.data(), 1, 4, f);
    std::vector<uint8_t> body(type, type + 4);
    body.insert(body.end(), data.begin(), data.end());
    fwrite(body.data(), 1, body.size(), f);
    std::vector<uint8_t> crc;
    Be32(crc, (uint32_t)crc32(0, body.data(), (uInt)body.size()));
    fwrite(crc.data(), 1, 4, f);
}

static bool WritePng(const std::string& path, DSCore* core)
{
    const int k = ds_3d_scale(core);
    const int SW = DS_SCREEN_WIDTH * k, SH = DS_SCREEN_HEIGHT * k;
    const int W = SW, H = SH * 2;
    // 화면마다: 고해상도 그림이 있으면 그것, 없으면 1×를 k배로
    std::vector<uint32_t> hires[2];
    bool has[2] = {};
    for (int s = 0; s < 2 && k > 1; s++)
    {
        hires[s].resize((size_t)SW * SH);
        int w = 0, h = 0;
        has[s] = ds_screen_hires(core, s, hires[s].data(), SW * SH, &w, &h) > 0 && w == SW && h == SH;
    }
    std::vector<uint8_t> raw;
    raw.reserve((W * 3 + 1) * H);
    for (int y = 0; y < H; y++)
    {
        int s = y >= SH;
        const uint32_t* src = ds_screen(core, s);
        int sy = y % SH;
        raw.push_back(0);
        for (int x = 0; x < W; x++)
        {
            uint32_t p;   // BGRA 메모리 = 0xAARRGGBB
            if (has[s]) p = hires[s][(size_t)sy * SW + x];
            else p = src ? src[(sy / k) * DS_SCREEN_WIDTH + x / k] : 0;
            raw.push_back((p >> 16) & 0xFF);
            raw.push_back((p >> 8) & 0xFF);
            raw.push_back(p & 0xFF);
        }
    }
    uLongf zlen = compressBound((uLong)raw.size());
    std::vector<uint8_t> z(zlen);
    if (compress2(z.data(), &zlen, raw.data(), (uLong)raw.size(), 9) != Z_OK) return false;
    z.resize(zlen);

    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    fwrite(sig, 1, 8, f);
    std::vector<uint8_t> ihdr;
    Be32(ihdr, W); Be32(ihdr, H);
    ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});
    Chunk(f, "IHDR", ihdr);
    Chunk(f, "IDAT", z);
    Chunk(f, "IEND", {});
    fclose(f);
    return true;
}

static void WriteWav(const std::string& path, const std::vector<int16_t>& pcm)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    auto le32 = [&](uint32_t x) { fwrite(&x, 4, 1, f); };
    auto le16 = [&](uint16_t x) { fwrite(&x, 2, 1, f); };
    uint32_t bytes = (uint32_t)(pcm.size() * 2);
    fwrite("RIFF", 1, 4, f); le32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
    le32(16); le16(1); le16(2); le32(DS_AUDIO_RATE); le32(DS_AUDIO_RATE * 4); le16(4); le16(16);
    fwrite("data", 1, 4, f); le32(bytes);
    fwrite(pcm.data(), 2, pcm.size(), f);
    fclose(f);
}

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: dsrun <rom> [options]\n"); return 2; }
    std::string rom = argv[1];
    int frames = 300;
    bool quiet = false;
    int scale = 1;
    std::string png, wav, save;
    std::vector<Press> presses;
    std::vector<ScaleOp> scaleOps;   // 도중에 3D 배율 바꾸기(앱 설정처럼)
    std::vector<Touch> touches;
    std::vector<Blow> blows;
    std::vector<Lid> lids;
    std::vector<Shot> shots;
    std::vector<StateOp> states;

    for (int i = 2; i < argc; i++)
    {
        std::string a = argv[i];
        auto next = [&]() -> std::string { if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); } return argv[++i]; };
        if (a == "--frames") frames = atoi(next().c_str());
        else if (a == "--png") png = next();
        else if (a == "--wav") wav = next();
        else if (a == "--save") save = next();
        else if (a == "--quiet") quiet = true;
        else if (a == "--scale") scale = atoi(next().c_str());
        else if (a == "--scale-at") { ScaleOp o; int to; std::string rest; ParseRange(next(), o.frame, to, rest); o.scale = atoi(rest.c_str()); scaleOps.push_back(o); }
        else if (a == "--press") { Press p; std::string rest; ParseRange(next(), p.from, p.to, rest); p.keys = ParseKeys(rest); presses.push_back(p); }
        else if (a == "--touch") { Touch t; std::string rest; ParseRange(next(), t.from, t.to, rest); sscanf(rest.c_str(), "%d,%d", &t.x, &t.y); touches.push_back(t); }
        else if (a == "--blow") { Blow b; std::string rest; ParseRange(next(), b.from, b.to, rest); blows.push_back(b); }
        else if (a == "--lid") { Lid l; std::string rest; ParseRange(next(), l.from, l.to, rest); lids.push_back(l); }
        else if (a == "--png-at") { Shot s; int to; ParseRange(next(), s.frame, to, s.path); shots.push_back(s); }
        else if (a == "--state-save" || a == "--state-load") { StateOp o; int to; ParseRange(next(), o.frame, to, o.path); o.save = a == "--state-save"; states.push_back(o); }
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }

    if (quiet) ds_set_log_handler([](int, const char*) {});
    DSCore* core = ds_create();
    char err[256] = {};
    ds_set_3d_scale(core, scale);
    if (ds_load_rom(core, rom.c_str(), save.empty() ? nullptr : save.c_str(), err, sizeof(err)) != 0)
    {
        fprintf(stderr, "load failed: %s\n", err);
        return 1;
    }
    if (scale > 1 && !quiet) printf("3D scale %d\n", ds_3d_scale(core));

    std::vector<int16_t> pcm;
    int16_t buf[4096 * 2];
    double sumSq = 0;
    long samples = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (int f = 0; f < frames; f++)
    {
        uint32_t keys = 0;
        for (auto& p : presses) if (f >= p.from && f <= p.to) keys |= p.keys;
        ds_set_keys(core, keys);
        bool touching = false;
        for (auto& t : touches) if (f >= t.from && f <= t.to) { ds_set_touch(core, 1, t.x, t.y); touching = true; }
        if (!touching) ds_set_touch(core, 0, 0, 0);
        bool blowing = false;
        for (auto& b : blows) if (f >= b.from && f <= b.to) blowing = true;
        ds_set_mic_blow(core, blowing);
        bool lid = false;
        for (auto& l : lids) if (f >= l.from && f <= l.to) lid = true;
        ds_set_lid_closed(core, lid);
        for (auto& o : states)
        {
            if (o.frame != f) continue;
            int r = o.save ? ds_save_state(core, o.path.c_str()) : ds_load_state(core, o.path.c_str());
            printf("frame %d: %s state %s → %d\n", f, o.save ? "save" : "load", o.path.c_str(), r);
        }

        for (auto& o : scaleOps) if (o.frame == f) ds_set_3d_scale(core, o.scale);
        ds_run_frame(core);

        int n;
        while ((n = ds_read_audio(core, buf, 4096)) > 0)
        {
            for (int i = 0; i < n * 2; i++) sumSq += (double)buf[i] * buf[i];
            samples += n * 2;
            if (!wav.empty()) pcm.insert(pcm.end(), buf, buf + n * 2);
        }
        for (auto& s : shots) if (s.frame == f) WritePng(s.path, core);
        if (!ds_is_running(core)) { printf("stopped at frame %d\n", f); break; }
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    printf("frames %d in %.2fs = %.1f fps (%.1fx real time)\n", frames, secs, frames / secs, frames / secs / 59.8261);
    printf("audio %ld frames (%.2fs), rms %.1f\n", samples / 2, samples / 2.0 / DS_AUDIO_RATE, samples ? std::sqrt(sumSq / samples) : 0.0);
    printf("asleep %d\n", ds_is_asleep(core));
    if (!png.empty()) printf("png %s: %s\n", png.c_str(), WritePng(png, core) ? "ok" : "failed");
    if (!wav.empty()) WriteWav(wav, pcm);
    if (!save.empty()) printf("save flush: %d\n", ds_flush_save(core));
    ds_destroy(core);
    return 0;
}
