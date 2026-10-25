// nettest — DS 인터넷(사설 서버) 길을 게임 없이 시험한다. 게임 대신 이더넷 프레임을 가상 공유기 뒤로 보낸다.
//   nettest [서버DNS]      기본 95.217.77.151(Wiimmfi)
// 1. 서버 DNS에 직접 묻기(ds_net_probe)  2. DHCP로 주소 받기(slirp)  3. 게임의 DNS 질의가 서버로 가는지(가상 DNS · 아무 주소)
// 4. TCP 연결(SYN → SYN-ACK)  5. UDP(NTP)  6. 인터넷 끄면 답이 없는지  7. Nintendo WFC 설정 남기기 · 되살리기 · 지우기

#include "DSCore.h"
#include "SPI_Firmware.h"

#include <arpa/inet.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <string>
#include <thread>
#include <sys/stat.h>
#include <unistd.h>

void DSCore_WriteFirmware(const melonDS::Firmware& fw, melonDS::u32 offset, melonDS::u32 len);

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;

static int g_Fail = 0;
static void Check(bool ok, const std::string& what, const std::string& detail = "")
{
    printf("%s %s%s%s\n", ok ? "  통과" : "  실패", what.c_str(), detail.empty() ? "" : " — ", detail.c_str());
    if (!ok) g_Fail++;
}

static const u8 kMyMac[6] = {0x00, 0x09, 0xBF, 0x12, 0x34, 0x56};
static const u8 kBroadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
static u8 g_GatewayMac[6];
static u32 g_MyIP = 0;          // 네트워크 순서

static u16 R16(const u8* p) { return (u16)(p[0] << 8 | p[1]); }
static void W16(u8* p, u16 v) { p[0] = (u8)(v >> 8); p[1] = (u8)v; }
static u32 Sum(const u8* p, int len, u32 s = 0)
{
    for (int i = 0; i + 1 < len; i += 2) s += R16(p + i);
    if (len & 1) s += (u32)p[len - 1] << 8;
    return s;
}
static u16 Fold(u32 s) { while (s >> 16) s = (s & 0xFFFF) + (s >> 16); return (u16)~s; }
static std::string Ip(u32 a) { char b[32]; inet_ntop(AF_INET, &a, b, sizeof(b)); return b; }
static std::string Ip(const u8* p) { u32 a; memcpy(&a, p, 4); return Ip(a); }

// IPv4 프레임(이더넷 + IP + 꼬리) — 체크섬 채움
static int Frame(u8* f, const u8* dstMac, u32 src, u32 dst, u8 proto, const u8* l4, int l4len)
{
    memcpy(f, dstMac, 6);
    memcpy(f + 6, kMyMac, 6);
    W16(f + 12, 0x0800);
    u8* ip = f + 14;
    memset(ip, 0, 20);
    ip[0] = 0x45;
    W16(ip + 2, (u16)(20 + l4len));
    W16(ip + 4, (u16)rand());
    ip[8] = 64;
    ip[9] = proto;
    memcpy(ip + 12, &src, 4);
    memcpy(ip + 16, &dst, 4);
    W16(ip + 10, Fold(Sum(ip, 20)));
    memcpy(ip + 20, l4, l4len);
    u8* l = ip + 20;
    int ck = proto == 17 ? 6 : 16;
    W16(l + ck, 0);
    u16 c = Fold(Sum(l, l4len, Sum(ip + 12, 8) + proto + (u32)l4len));
    W16(l + ck, proto == 17 && c == 0 ? 0xFFFF : c);
    return 14 + 20 + l4len;
}

static int Udp(u8* f, const u8* dstMac, u32 src, u32 dst, u16 sport, u16 dport, const u8* data, int len)
{
    u8 l4[1600];
    W16(l4, sport);
    W16(l4 + 2, dport);
    W16(l4 + 4, (u16)(8 + len));
    W16(l4 + 6, 0);
    memcpy(l4 + 8, data, len);
    return Frame(f, dstMac, src, dst, 17, l4, 8 + len);
}

// 받은 IPv4 프레임의 체크섬이 맞는지
static bool ChecksumsOK(const u8* f, int len)
{
    const u8* ip = f + 14;
    int ihl = (ip[0] & 0xF) * 4, total = R16(ip + 2);
    if (14 + total > len || Fold(Sum(ip, ihl)) != 0) return false;
    int l4len = total - ihl;
    if (ip[9] == 17 && R16(ip + ihl + 6) == 0) return true;   // UDP 체크섬 생략
    return Fold(Sum(ip + ihl, l4len, Sum(ip + 12, 8) + ip[9] + (u32)l4len)) == 0;
}

// 프레임을 받을 때까지(ARP 물음엔 대신 답한다). match가 참인 것을 돌려준다
static int Wait(u8* out, int ms, const std::function<bool(const u8*, int)>& match)
{
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < end)
    {
        int n = ds_net_recv_frame(out);
        if (n <= 0) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        if (R16(out + 12) == 0x0806 && R16(out + 20) == 1 && g_MyIP && memcmp(out + 38, &g_MyIP, 4) == 0)
        {
            u8 r[42];
            memcpy(r, out + 6, 6);
            memcpy(r + 6, kMyMac, 6);
            W16(r + 12, 0x0806);
            memcpy(r + 14, out + 14, 6);
            W16(r + 20, 2);
            memcpy(r + 22, kMyMac, 6);
            memcpy(r + 28, &g_MyIP, 4);
            memcpy(r + 32, out + 22, 10);
            ds_net_send_frame(r, 42);
            continue;
        }
        if (match(out, n)) return n;
    }
    return 0;
}

static bool IsUdpFrom(const u8* f, int n, u16 sport)
{
    return n > 42 && R16(f + 12) == 0x0800 && f[23] == 17 && R16(f + 14 + (f[14] & 0xF) * 4) == sport;
}

// ── DHCP ──
static int Dhcp(u8* f, u8 type, u32 xid, u32 requested, u32 server)
{
    u8 b[300] = {};
    b[0] = 1; b[1] = 1; b[2] = 6;
    memcpy(b + 4, &xid, 4);
    W16(b + 10, 0x8000);
    memcpy(b + 28, kMyMac, 6);
    u8* o = b + 236;
    *o++ = 99; *o++ = 130; *o++ = 83; *o++ = 99;
    *o++ = 53; *o++ = 1; *o++ = type;
    if (requested) { *o++ = 50; *o++ = 4; memcpy(o, &requested, 4); o += 4; }
    if (server) { *o++ = 54; *o++ = 4; memcpy(o, &server, 4); o += 4; }
    *o++ = 55; *o++ = 3; *o++ = 1; *o++ = 3; *o++ = 6;
    *o++ = 255;
    return Udp(f, kBroadcast, 0, 0xFFFFFFFF, 68, 67, b, sizeof(b));
}

static int DhcpOption(const u8* bootp, int len, u8 code, u8* out)
{
    for (int i = 240; i < len;)
    {
        u8 c = bootp[i];
        if (c == 255) break;
        if (c == 0) { i++; continue; }
        u8 l = bootp[i + 1];
        if (c == code) { memcpy(out, bootp + i + 2, l); return l; }
        i += 2 + l;
    }
    return -1;
}

// ── DNS ──
static int DnsQuery(u8* q, const char* name, u16 id)
{
    memset(q, 0, 12);
    W16(q, id); W16(q + 2, 0x0100); W16(q + 4, 1);
    int o = 12;
    for (const char* s = name; *s;)
    {
        const char* d = strchr(s, '.');
        int l = d ? (int)(d - s) : (int)strlen(s);
        q[o++] = (u8)l;
        memcpy(q + o, s, l);
        o += l;
        s += l + (d ? 1 : 0);
    }
    q[o++] = 0;
    W16(q + o, 1); W16(q + o + 2, 1);
    return o + 4;
}

static u32 DnsFirstA(const u8* m, int len)
{
    int off = 12;
    auto skip = [&](int o) { while (o < len) { if (m[o] == 0) return o + 1; if ((m[o] & 0xC0) == 0xC0) return o + 2; o += 1 + m[o]; } return len; };
    for (int i = 0; i < R16(m + 4); i++) off = skip(off) + 4;
    for (int i = 0; i < R16(m + 6) && off + 10 <= len; i++)
    {
        off = skip(off);
        u16 type = R16(m + off), rdlen = R16(m + off + 8);
        off += 10;
        if (type == 1 && rdlen == 4) { u32 a; memcpy(&a, m + off, 4); return a; }
        off += rdlen;
    }
    return 0;
}

// 게임처럼 dnsIP:53에 묻고, 그 주소에서 온 답의 첫 A를 돌려준다(체크섬도 본다)
static u32 AskThrough(u32 dnsIP, const char* name, bool* sumsOK, int ms = 5000)
{
    u8 q[300], f[2048];
    u16 id = (u16)rand(), sport = (u16)(40000 + rand() % 20000);
    int ql = DnsQuery(q, name, id);
    ds_net_send_frame(f, Udp(f, g_GatewayMac, g_MyIP, dnsIP, sport, 53, q, ql));
    int n = Wait(f, ms, [&](const u8* r, int len) {
        return IsUdpFrom(r, len, 53) && memcmp(r + 26, &dnsIP, 4) == 0 && R16(r + 36) == sport && R16(r + 42) == id;
    });
    if (!n) return 0;
    if (sumsOK) *sumsOK = ChecksumsOK(f, n);
    return DnsFirstA(f + 42, n - 42);
}

// 게임처럼 TCP로 붙어(SYN → SYN-ACK → ACK) request를 보내고(없으면 서버가 먼저 말하길 기다린다) 처음 받은 데이터를 돌려준다. 끝은 RST
static std::string TcpTalk(u32 ip, u16 port, const char* request, int ms = 8000)
{
    u8 f[2048];
    u16 cport = (u16)(40000 + rand() % 20000);
    u32 s0 = (u32)rand();
    int rlen = request ? (int)strlen(request) : 0;
    auto seg = [&](u32 sq, u32 ak, u8 flags, const char* data, int dl) {
        u8 t[20 + 512] = {};
        W16(t, cport); W16(t + 2, port);
        u32 v = htonl(sq); memcpy(t + 4, &v, 4);
        v = htonl(ak); memcpy(t + 8, &v, 4);
        t[12] = 5 << 4; t[13] = flags; W16(t + 14, 8192);
        memcpy(t + 20, data, dl);
        ds_net_send_frame(f, Frame(f, g_GatewayMac, g_MyIP, ip, 6, t, 20 + dl));
    };
    auto fromServer = [&](const u8* r, int len) {
        return len > 54 && R16(r + 12) == 0x0800 && r[23] == 6 && memcmp(r + 26, &ip, 4) == 0 && R16(r + 36) == cport;
    };
    seg(s0, 0, 0x02, nullptr, 0);
    int n = Wait(f, ms, fromServer);
    if (!n || (f[47] & 0x12) != 0x12) return "";
    u32 r0;
    memcpy(&r0, f + 38, 4);
    r0 = ntohl(r0);
    seg(s0 + 1, r0 + 1, 0x10, nullptr, 0);
    if (request) seg(s0 + 1, r0 + 1, 0x18, request, rlen);
    std::string got;
    n = Wait(f, ms, [&](const u8* r, int len) {
        return fromServer(r, len) && 14 + R16(r + 16) > 14 + 20 + (r[46] >> 4) * 4;
    });
    if (n)
    {
        int dataOff = 14 + 20 + (f[46] >> 4) * 4, total = 14 + R16(f + 16);
        got.assign((const char*)f + dataOff, total - dataOff);
    }
    seg(s0 + 1 + rlen, r0 + 1, 0x04, nullptr, 0);
    return got;
}

int main(int argc, char** argv)
{
    const char* dns = argc > 1 ? argv[1] : "95.217.77.151";
    srand((unsigned)time(nullptr));
    ds_set_log_handler([](int, const char*) {});
    u8 f[2048];
    char logDir[] = "/tmp/duods-netlog-XXXXXX";
    if (!mkdtemp(logDir)) { perror("mkdtemp"); return 1; }
    std::string logPath = std::string(logDir) + "/wfc.txt";
    ds_net_set_log(logPath.c_str());
    ds_net_log_note("nettest 시작");

    printf("[1] 서버 DNS(%s)에 직접 묻기\n", dns);
    char nas[64] = "", conn[64] = "";
    Check(ds_net_probe(dns, "nas.nintendowifi.net", nas, sizeof(nas), 3000) == 0, "nas.nintendowifi.net", nas);
    Check(ds_net_probe(dns, "conntest.nintendowifi.net", conn, sizeof(conn), 3000) == 0, "conntest.nintendowifi.net", conn);
    Check(ds_net_probe("192.0.2.1", "nas.nintendowifi.net", nullptr, 0, 800) != 0, "없는 서버는 실패로");

    printf("[2] 가상 공유기 뒤에서 DHCP\n");
    Check(ds_net_set_server("1.2.3") != 0, "틀린 주소는 거절");
    Check(ds_net_set_server(dns) == 0, "인터넷 켜기");
    u32 xid = (u32)rand();
    ds_net_send_frame(f, Dhcp(f, 1, xid, 0, 0));
    int n = Wait(f, 3000, [&](const u8* r, int len) { return IsUdpFrom(r, len, 67) && memcmp(r + 42 + 4, &xid, 4) == 0; });
    u32 offered = 0, serverId = 0, router = 0, dnsOpt = 0;
    if (n)
    {
        const u8* bootp = f + 42;
        memcpy(&offered, bootp + 16, 4);
        memcpy(g_GatewayMac, f + 6, 6);
        DhcpOption(bootp, n - 42, 54, (u8*)&serverId);
        DhcpOption(bootp, n - 42, 3, (u8*)&router);
        DhcpOption(bootp, n - 42, 6, (u8*)&dnsOpt);
    }
    Check(n && offered, "DHCP 제안", "주소 " + Ip(offered) + " · 공유기 " + Ip(router) + " · DNS " + Ip(dnsOpt));
    if (!offered) { printf("더 갈 수 없음\n"); return 1; }
    ds_net_send_frame(f, Dhcp(f, 3, xid, offered, serverId));
    n = Wait(f, 3000, [&](const u8* r, int len) {
        u8 t = 0;
        return IsUdpFrom(r, len, 67) && memcmp(r + 42 + 4, &xid, 4) == 0 && DhcpOption(r + 42, len - 42, 53, &t) == 1 && t == 5;
    });
    Check(n > 0, "DHCP 확인(ACK)");
    g_MyIP = offered;

    printf("[3] 게임의 DNS 질의 → 서버\n");
    bool sums = false;
    u32 a = AskThrough(dnsOpt, "nas.nintendowifi.net", &sums);
    Check(a && Ip(a) == nas, "가상 DNS(" + Ip(dnsOpt) + ")로 물으면 서버의 답", Ip(a));
    Check(sums, "답 프레임의 IP · UDP 체크섬");
    u32 other = inet_addr("8.8.8.8");
    a = AskThrough(other, "nas.nintendowifi.net", &sums);
    Check(a && Ip(a) == nas, "게임이 다른 DNS(8.8.8.8)로 물어도 서버로", Ip(a));
    a = AskThrough(dnsOpt, "conntest.nintendowifi.net", nullptr);
    Check(a != 0, "conntest.nintendowifi.net", Ip(a));   // 주소가 여럿이라(돌려 가며 답한다) 직접 물은 것과 순서가 다를 수 있다

    printf("[4] TCP — %s:443에 SYN\n", nas);
    u32 nasIP = inet_addr(nas);
    u8 tcp[20] = {};
    u16 sport = (u16)(40000 + rand() % 20000);
    u32 seq = (u32)rand();
    W16(tcp, sport); W16(tcp + 2, 443);
    u32 nseq = htonl(seq); memcpy(tcp + 4, &nseq, 4);
    tcp[12] = 5 << 4; tcp[13] = 0x02; W16(tcp + 14, 8192);
    ds_net_send_frame(f, Frame(f, g_GatewayMac, g_MyIP, nasIP, 6, tcp, 20));
    auto t0 = std::chrono::steady_clock::now();
    n = Wait(f, 8000, [&](const u8* r, int len) {
        return len > 54 && R16(r + 12) == 0x0800 && r[23] == 6 && memcmp(r + 26, &nasIP, 4) == 0 && R16(r + 36) == sport;
    });
    int ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    bool synack = n && (f[14 + 20 + 13] & 0x12) == 0x12;
    Check(synack, "SYN-ACK", std::to_string(ms) + "ms");
    if (synack)
    {
        Check(ChecksumsOK(f, n), "SYN-ACK 체크섬");
        // RST로 닫는다
        u8 rst[20] = {};
        W16(rst, sport); W16(rst + 2, 443);
        nseq = htonl(seq + 1); memcpy(rst + 4, &nseq, 4);
        rst[12] = 5 << 4; rst[13] = 0x04;
        ds_net_send_frame(f, Frame(f, g_GatewayMac, g_MyIP, nasIP, 6, rst, 20));
    }

    printf("[4b] TCP — 게임의 접속 시험처럼 http://conntest.nintendowifi.net/ 받기\n");
    std::string body = TcpTalk(inet_addr(conn), 80, "GET / HTTP/1.0\r\nHost: conntest.nintendowifi.net\r\nUser-Agent: Nitro WiFi SDK/5.1\r\n\r\n");
    Check(body.rfind("HTTP/1.", 0) == 0, "HTTP 답", body.substr(0, body.find('\r')));

    printf("[4c] TCP — GameSpy 로그인 서버(gpcm:29900)가 먼저 인사하는지\n");
    u32 gpcm = AskThrough(dnsOpt, "gpcm.gs.nintendowifi.net", nullptr);
    std::string hello = gpcm ? TcpTalk(gpcm, 29900, nullptr) : "";
    Check(hello.rfind("\\lc\\1\\", 0) == 0, "gpcm.gs.nintendowifi.net(" + Ip(gpcm) + ") 인사", hello.substr(0, 40));

    printf("[5] UDP — NTP\n");
    char ntp[64] = "";
    ds_net_probe(dns, "time.apple.com", ntp, sizeof(ntp), 3000);
    u32 ntpIP = inet_addr(ntp);
    u8 req[48] = {0x1B};
    u16 nport = (u16)(40000 + rand() % 20000);
    ds_net_send_frame(f, Udp(f, g_GatewayMac, g_MyIP, ntpIP, nport, 123, req, 48));
    n = Wait(f, 5000, [&](const u8* r, int len) { return IsUdpFrom(r, len, 123) && R16(r + 36) == nport; });
    Check(n >= 42 + 48, "time.apple.com(" + std::string(ntp) + ") 답", std::to_string(n > 42 ? n - 42 : 0) + "바이트");

    DSNetStatus st;
    ds_net_status(&st);
    printf("    상태: 질의 %u · 답 %u · 실패 %u · 보냄 %llu · 받음 %llu · 마지막 %s → %s\n", st.dns_queries, st.dns_answers,
           st.dns_failures, (unsigned long long)st.bytes_out, (unsigned long long)st.bytes_in, st.last_name, Ip(st.last_address).c_str());
    Check(st.dns_queries == 4 && st.dns_answers == 4 && st.bytes_in > 0, "상태 숫자");

    printf("[6] 인터넷 끄기\n");
    ds_net_set_server("");
    a = AskThrough(dnsOpt, "nas.nintendowifi.net", nullptr, 800);
    Check(a == 0, "끄면 답이 없다");
    ds_net_status(&st);
    Check(!st.enabled, "상태: 꺼짐");

    printf("[7] Nintendo WFC 설정 남기기 · 되살리기 · 지우기\n");
    char dir[] = "/tmp/duods-nettest-XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    ds_set_local_dir(dir);
    Check(ds_wfc_configured() == 0, "처음엔 접속 ID 없음");
    {
        melonDS::Firmware fw(0);
        auto& ap = fw.GetAccessPoints()[0];
        const u8 id[6] = {1, 2, 3, 4, 5, 6};
        memcpy(ap.NintendoWFCID, id, 6);
        ap.UpdateChecksum();
        DSCore_WriteFirmware(fw, fw.GetUserDataOffset(), 0x100);   // 본체 설정 자리 — 남기지 않는다
        Check(ds_wfc_configured() == 0, "본체 설정을 쓴 것은 무시");
        DSCore_WriteFirmware(fw, fw.GetWifiAccessPointOffset() + 0xF0, 6);
        Check(ds_wfc_configured() == 1, "접속 ID를 쓰면 남는다");
    }
    static std::string logs;
    ds_set_log_handler([](int, const char* t) { logs += t; });
    DSCore* core = ds_create();
    char err[256] = "";
    int rc = ds_load_rom(core, "build/test.nds", nullptr, err, sizeof(err));
    if (rc == 0) for (int i = 0; i < 10; i++) ds_run_frame(core);
    Check(rc == 0 && logs.find("WFC 설정을 되살림") != std::string::npos, "다음 켤 때 되살림", rc ? err : "");
    ds_destroy(core);
    Check(ds_wfc_reset() == 0 && ds_wfc_configured() == 0, "지우기");
    Check(ds_wfc_reset() == 0, "없는 것을 지워도 성공");
    rmdir(dir);

    printf("[8] 접속 기록\n");
    ds_net_set_log(nullptr);   // 닫아서 다 쓰이게
    std::string log;
    if (FILE* lf = fopen(logPath.c_str(), "rb")) { char b[4096]; size_t k; while ((k = fread(b, 1, sizeof(b), lf)) > 0) log.append(b, k); fclose(lf); }
    const char* want[] = {"── nettest 시작 ──", "── 인터넷 켬: 서버 DNS", "DHCP → discover", "DHCP ← offer — 주소 10.64.0.16", "DHCP ← ack",
                          "DNS ? nas.nintendowifi.net", "DNS = nas.nintendowifi.net → ", "TCP → conntest.nintendowifi.net(",
                          "GET / HTTP/1.0\\r\\nHost: conntest", "바이트: HTTP/1.", "TCP ← gpcm.gs.nintendowifi.net(", "\\lc\\1\\challenge\\",
                          "RST(끊음)", "UDP → ", "── 인터넷 끔 ──"};
    for (const char* w : want) Check(log.find(w) != std::string::npos, std::string("기록에 \"") + w + "\"");
    if (getenv("NETTEST_SHOWLOG")) printf("%s", log.c_str());
    ds_net_set_log(logPath.c_str());
    ds_net_clear_log();
    ds_net_set_log(nullptr);
    struct stat lst;
    Check(stat(logPath.c_str(), &lst) == 0 && lst.st_size == 0, "기록 지우기");
    remove(logPath.c_str());
    rmdir(logDir);

    printf(g_Fail ? "\n%d개 실패\n" : "\n모두 통과\n", g_Fail);
    return g_Fail ? 1 : 0;
}
