// DuoNet.cpp — DS 인터넷(Nintendo WFC 대체 서버). DSCore.h의 ds_net_* 와 Platform의 Net_SendPacket · Net_RecvPacket.
// melonDS의 가상 공유기(WifiAP)가 게임의 무선 프레임을 이더넷 프레임으로 바꿔 넘기면, libslirp(Net_Slirp — 사용자 공간 NAT)가
// 이 기기의 보통 소켓으로 인터넷에 잇는다(DHCP · ARP도 slirp가 답한다) — 아이폰에서 따로 받을 권한이 없다.
// DNS(UDP 53)만은 slirp에 넘기지 않고 여기서 고른 서버에 직접 묻는다 → 게임 안 DNS 설정과 상관없이 사설 서버로 간다.
// 접속 기록(ds_net_set_log)을 켜 두면 오가는 프레임을 들여다보고 글로 남긴다 — 서버가 무엇을 거절했는지 보려고.

#include "DSCore.h"
#include "Net.h"
#include "Net_Slirp.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <map>
#include <string>
#include <sys/stat.h>
#include <sys/time.h>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

using namespace melonDS;

namespace
{

std::mutex g_Lock;
std::unique_ptr<Net> g_Net;     // 인터넷을 켜 두는 동안만
DSNetStatus g_Status{};
u16 g_IPv4ID = 1;

// 서버에 넘긴 DNS 질의 — 답이 오면 게임이 물은 주소에서 온 것처럼 되돌린다
struct PendingDns
{
    int fd;
    u8 dsMac[6], apMac[6];
    u8 dsIP[4], dnsIP[4];
    u16 dsPort;
    u64 deadline;
    char name[64];
};
std::vector<PendingDns> g_Pending;
constexpr u64 kDnsTimeoutMS = 4000;

// ── 접속 기록(원인 찾기) ─────────────────────────
// 게임이 어디에 붙었고 서버가 뭐라고 답했는지 글로 남긴다: DHCP · DNS 질의와 답 · TCP 연결과 끊김(주고받은 양).
// 암호 없는 내용(GameSpy 로그인 29900 · 친구 검색 29901 · HTTP 80)은 글자 그대로, 그 밖의 TCP(HTTPS 443 등)는
// 처음 몇 바이트만 16진수로, UDP는 상대마다 처음 3개만. 모두 에뮬레이션 스레드에서 g_Lock 아래.

FILE* g_Log = nullptr;
constexpr long kLogMax = 512 * 1024;   // 넘으면 .old로 옮기고 새로
std::map<u32, std::string> g_Names;    // IPv4(네트워크 순서) → 게임이 물은 이름

struct TcpFlow
{
    u32 next[2] = {};    // [0] 게임 → 서버 · [1] 서버 → 게임 — 다음에 올 순번(다시 보낸 것은 건너뛴다)
    bool have[2] = {};
    u64 bytes[2] = {};
    int fins = 0;
};
std::map<u64, TcpFlow> g_Tcp;          // 키 = 상대 IP << 32 | 상대 포트 << 16 | 게임 포트
std::map<u64, int> g_UdpSeen;          // 키 = 상대 IP << 32 | 상대 포트 << 16 | 방향

void LogLine(const char* fmt, ...)
{
    if (!g_Log) return;
    timeval tv;
    gettimeofday(&tv, nullptr);
    tm t;
    localtime_r(&tv.tv_sec, &t);
    fprintf(g_Log, "%02d:%02d:%02d.%03d ", t.tm_hour, t.tm_min, t.tm_sec, (int)(tv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_Log, fmt, ap);
    va_end(ap);
    fputc('\n', g_Log);
    fflush(g_Log);
}

std::string IpText(u32 a)
{
    char b[INET_ADDRSTRLEN] = "";
    inet_ntop(AF_INET, &a, b, sizeof(b));
    return b;
}

// "gpcm.gs.nintendowifi.net(95.217.77.151):29900"
std::string Peer(u32 ip, u16 port)
{
    auto it = g_Names.find(ip);
    std::string s = it != g_Names.end() ? it->second + "(" + IpText(ip) + ")" : IpText(ip);
    return s + ":" + std::to_string(port);
}

// 보이는 글자는 그대로, 줄바꿈은 \r \n, 나머지는 \xNN
std::string Printable(const u8* p, int n, int cap)
{
    std::string s;
    for (int i = 0; i < n && (int)s.size() < cap; i++)
    {
        u8 c = p[i];
        if (c == '\r') s += "\\r";
        else if (c == '\n') s += "\\n";
        else if (c >= 0x20 && c < 0x7F) s += (char)c;
        else { char b[8]; snprintf(b, sizeof(b), "\\x%02X", c); s += b; }
    }
    if ((int)s.size() >= cap) s += "…(줄임)";
    return s;
}

std::string Hex(const u8* p, int n)
{
    std::string s;
    for (int i = 0; i < n; i++) { char b[4]; snprintf(b, sizeof(b), i ? " %02X" : "%02X", p[i]); s += b; }
    return s;
}

bool PlainPort(u16 port) { return port == 80 || port == 29900 || port == 29901; }

const char* DhcpType(const u8* bootp, int len)
{
    for (int i = 240; i + 2 < len;)
    {
        if (bootp[i] == 255) break;
        if (bootp[i] == 0) { i++; continue; }
        if (bootp[i] == 53 && bootp[i + 1] == 1)
        {
            static const char* names[] = {"?", "discover", "offer", "request", "decline", "ack", "nak", "release", "inform"};
            return bootp[i + 2] <= 8 ? names[bootp[i + 2]] : "?";
        }
        i += 2 + bootp[i + 1];
    }
    return "?";
}

void Inspect(const u8* f, int len, bool out);

u64 NowMS()
{
    using namespace std::chrono;
    return (u64)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

u16 Read16(const u8* p) { return (u16)(p[0] << 8 | p[1]); }
void Write16(u8* p, u16 v) { p[0] = (u8)(v >> 8); p[1] = (u8)v; }

u32 SumWords(const u8* p, int len, u32 sum)
{
    for (int i = 0; i + 1 < len; i += 2) sum += Read16(p + i);
    if (len & 1) sum += (u32)p[len - 1] << 8;
    return sum;
}

u16 Fold(u32 sum)
{
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (u16)~sum;
}

// ── DNS 메시지 ─────────────────────────────────

// 이름(라벨 · 압축 포인터)을 건너뛴 위치 — 틀리면 -1
int SkipName(const u8* msg, int len, int off)
{
    while (off < len)
    {
        u8 l = msg[off];
        if (l == 0) return off + 1;
        if ((l & 0xC0) == 0xC0) return off + 2 <= len ? off + 2 : -1;
        off += 1 + l;
    }
    return -1;
}

// 첫 질문의 이름을 점으로 이어서
void QuestionName(const u8* msg, int len, char* out, int outlen)
{
    int off = 12, o = 0;
    while (off < len && msg[off] != 0 && (msg[off] & 0xC0) == 0)
    {
        int l = msg[off++];
        if (o > 0 && o < outlen - 1) out[o++] = '.';
        for (int i = 0; i < l && off < len; i++, off++)
            if (o < outlen - 1) out[o++] = (char)msg[off];
    }
    out[o] = 0;
}

// 답의 첫 A 레코드(네트워크 순서) — 없으면 0
u32 FirstA(const u8* msg, int len)
{
    if (len < 12) return 0;
    int qd = Read16(msg + 4), an = Read16(msg + 6);
    int off = 12;
    for (int i = 0; i < qd; i++)
    {
        off = SkipName(msg, len, off);
        if (off < 0 || off + 4 > len) return 0;
        off += 4;
    }
    for (int i = 0; i < an; i++)
    {
        off = SkipName(msg, len, off);
        if (off < 0 || off + 10 > len) return 0;
        u16 type = Read16(msg + off), cls = Read16(msg + off + 2), rdlen = Read16(msg + off + 8);
        off += 10;
        if (off + rdlen > len) return 0;
        if (type == 1 && cls == 1 && rdlen == 4)
        {
            u32 a;
            memcpy(&a, msg + off, 4);
            return a;
        }
        off += rdlen;
    }
    return 0;
}

int BuildQuery(const char* name, u16 id, u8* out, int outlen)
{
    if (outlen < 12 + 256 + 4) return -1;
    memset(out, 0, 12);
    Write16(out, id);
    Write16(out + 2, 0x0100);   // 재귀 요청
    Write16(out + 4, 1);
    int o = 12;
    const char* s = name;
    while (*s)
    {
        const char* dot = strchr(s, '.');
        int l = dot ? (int)(dot - s) : (int)strlen(s);
        if (l == 0 || l > 63 || o + 1 + l > 12 + 254) return -1;
        out[o++] = (u8)l;
        memcpy(out + o, s, l);
        o += l;
        s += l;
        if (*s == '.') s++;
    }
    out[o++] = 0;
    Write16(out + o, 1);        // A
    Write16(out + o + 2, 1);    // IN
    return o + 4;
}

// 서버(dns:53)로 이어 둔 UDP 소켓에 질의를 보낸다 — 이어 두면 그 서버의 답만 받는다
int SendToDns(u32 dns, const u8* query, int qlen)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    sockaddr_in to{};
    to.sin_len = sizeof(to);
    to.sin_family = AF_INET;
    to.sin_port = htons(53);
    to.sin_addr.s_addr = dns;
    if (connect(fd, (sockaddr*)&to, sizeof(to)) != 0 || send(fd, query, qlen, 0) != qlen)
    {
        close(fd);
        return -1;
    }
    return fd;
}

// ── 게임의 DNS 질의 가로채기 ───────────────────────

// IPv4 · UDP · 받는 포트 53 · 조각 아님
bool IsDnsQuery(const u8* f, int len)
{
    if (len < 14 + 20 + 8 + 12 || Read16(f + 12) != 0x0800) return false;
    const u8* ip = f + 14;
    int ihl = (ip[0] & 0xF) * 4;
    if ((ip[0] >> 4) != 4 || ihl < 20 || ip[9] != 17 || (Read16(ip + 6) & 0x3FFF) != 0) return false;
    if (14 + ihl + 8 + 12 > len) return false;
    return Read16(ip + ihl + 2) == 53;
}

void ForwardDns(const u8* f, int len)
{
    const u8* ip = f + 14;
    int ihl = (ip[0] & 0xF) * 4;
    const u8* udp = ip + ihl;
    int body = std::min<int>(Read16(udp + 4) - 8, len - (14 + ihl + 8));
    if (body < 12) return;

    PendingDns p{};
    memcpy(p.dsMac, f + 6, 6);
    memcpy(p.apMac, f, 6);
    memcpy(p.dsIP, ip + 12, 4);
    memcpy(p.dnsIP, ip + 16, 4);
    p.dsPort = Read16(udp);
    p.deadline = NowMS() + kDnsTimeoutMS;
    QuestionName(udp + 8, body, p.name, sizeof(p.name));

    g_Status.dns_queries++;
    strlcpy(g_Status.last_name, p.name, sizeof(g_Status.last_name));
    g_Status.last_address = 0;

    p.fd = SendToDns(g_Status.dns, udp + 8, body);
    if (p.fd < 0)
    {
        g_Status.dns_failures++;
        LogLine("DNS ✕ %s — 서버(%s)로 보내지 못함", p.name, IpText(g_Status.dns).c_str());
        return;
    }
    u32 asked;
    memcpy(&asked, ip + 16, 4);
    LogLine("DNS ? %s (게임이 %s에 물음 → 서버 %s)", p.name, IpText(asked).c_str(), IpText(g_Status.dns).c_str());
    g_Pending.push_back(p);
}

// 서버가 답한 것을 게임 쪽 이더넷 프레임으로(보낸 쪽 = 게임이 물은 DNS 주소)
void DeliverDns(const PendingDns& p, const u8* msg, int n)
{
    u8 f[14 + 20 + 8 + 1472 + 1];
    memcpy(f, p.dsMac, 6);
    memcpy(f + 6, p.apMac, 6);
    Write16(f + 12, 0x0800);

    u8* ip = f + 14;
    ip[0] = 0x45;
    ip[1] = 0;
    Write16(ip + 2, (u16)(20 + 8 + n));
    Write16(ip + 4, g_IPv4ID++);
    Write16(ip + 6, 0);
    ip[8] = 64;
    ip[9] = 17;
    Write16(ip + 10, 0);
    memcpy(ip + 12, p.dnsIP, 4);
    memcpy(ip + 16, p.dsIP, 4);
    Write16(ip + 10, Fold(SumWords(ip, 20, 0)));

    u8* udp = ip + 20;
    Write16(udp, 53);
    Write16(udp + 2, p.dsPort);
    Write16(udp + 4, (u16)(8 + n));
    Write16(udp + 6, 0);
    memcpy(udp + 8, msg, n);
    u32 sum = SumWords(ip + 12, 8, 0) + 17 + (u32)(8 + n);
    u16 c = Fold(SumWords(udp, 8 + n, sum));
    Write16(udp + 6, c ? c : 0xFFFF);

    int flen = 14 + 20 + 8 + n;
    if (flen & 1) f[flen++] = 0;   // melonDS의 DNS 답처럼 짝수 길이로
    g_Net->RXEnqueue(f, flen);
}

void PollDns()
{
    if (g_Pending.empty()) return;
    u64 now = NowMS();
    for (size_t i = 0; i < g_Pending.size();)
    {
        PendingDns& p = g_Pending[i];
        u8 msg[1472];
        ssize_t n = recv(p.fd, msg, sizeof(msg), 0);
        bool done = false;
        if (n >= 12)
        {
            DeliverDns(p, msg, (int)n);
            g_Status.dns_answers++;
            strlcpy(g_Status.last_name, p.name, sizeof(g_Status.last_name));
            g_Status.last_address = FirstA(msg, (int)n);
            if (g_Status.last_address) g_Names[g_Status.last_address] = p.name;
            LogLine("DNS = %s → %s", p.name, g_Status.last_address ? IpText(g_Status.last_address).c_str() : "A 레코드 없음");
            done = true;
        }
        else if (now > p.deadline)
        {
            g_Status.dns_failures++;
            LogLine("DNS ✕ %s — 4초 동안 답 없음", p.name);
            done = true;
        }
        if (done)
        {
            close(p.fd);
            g_Pending.erase(g_Pending.begin() + i);
        }
        else i++;
    }
}

void DropPending()
{
    for (auto& p : g_Pending) close(p.fd);
    g_Pending.clear();
}

// 이더넷 프레임 하나를 들여다보고 기록한다(out = 게임 → 인터넷). DNS는 ForwardDns · PollDns가 따로 남긴다
void Inspect(const u8* f, int len, bool out)
{
    if (!g_Log || len < 14 + 20 || Read16(f + 12) != 0x0800) return;
    const u8* ip = f + 14;
    int ihl = (ip[0] & 0xF) * 4, total = std::min<int>(Read16(ip + 2), len - 14);
    if ((ip[0] >> 4) != 4 || ihl < 20 || total < ihl + 8) return;
    u32 src, dst;
    memcpy(&src, ip + 12, 4);
    memcpy(&dst, ip + 16, 4);
    u32 remote = out ? dst : src;
    const u8* l4 = ip + ihl;
    int l4len = total - ihl;
    const char* arrow = out ? "→" : "←";

    if (ip[9] == 17)
    {
        u16 sport = Read16(l4), dport = Read16(l4 + 2);
        const u8* data = l4 + 8;
        int dlen = std::min<int>(Read16(l4 + 4) - 8, l4len - 8);
        if (dlen < 0 || sport == 53 || dport == 53) return;
        if (sport == 67 || dport == 67)
        {
            u32 yi = 0;
            if (dlen >= 20) memcpy(&yi, data + 16, 4);
            LogLine("DHCP %s %s%s", arrow, DhcpType(data, dlen), yi ? (" — 주소 " + IpText(yi)).c_str() : "");
            return;
        }
        u16 rport = out ? dport : sport;
        int& seen = g_UdpSeen[(u64)remote << 32 | (u64)rport << 16 | (out ? 0 : 1)];
        if (++seen > 3)
        {
            if (seen == 4) LogLine("UDP %s %s — 이후는 생략", arrow, Peer(remote, rport).c_str());
            return;
        }
        LogLine("UDP %s %s %d바이트: %s", arrow, Peer(remote, rport).c_str(), dlen, Printable(data, dlen, 200).c_str());
        return;
    }

    if (ip[9] != 6 || l4len < 20) return;
    u16 sport = Read16(l4), dport = Read16(l4 + 2);
    u32 seq = (u32)Read16(l4 + 4) << 16 | Read16(l4 + 6);
    int doff = (l4[12] >> 4) * 4;
    u8 flags = l4[13];
    if (doff < 20 || doff > l4len) return;
    const u8* data = l4 + doff;
    int dlen = l4len - doff;
    u16 rport = out ? dport : sport, dsport = out ? sport : dport;
    u64 key = (u64)remote << 32 | (u64)rport << 16 | dsport;
    std::string peer = Peer(remote, rport);
    int dir = out ? 0 : 1;

    if ((flags & 0x02) && !(flags & 0x10))
    {
        g_Tcp[key] = TcpFlow();
        LogLine("TCP %s %s 연결 시작", arrow, peer.c_str());
    }
    else if ((flags & 0x02) && (flags & 0x10))
    {
        LogLine("TCP %s %s 연결됨", arrow, peer.c_str());
    }
    auto it = g_Tcp.find(key);
    if (dlen > 0 && it != g_Tcp.end())
    {
        TcpFlow& fl = it->second;
        bool resent = fl.have[dir] && (s32)(seq + (u32)dlen - fl.next[dir]) <= 0;
        if (!resent)
        {
            bool first = fl.bytes[dir] == 0;
            fl.have[dir] = true;
            fl.next[dir] = seq + (u32)dlen;
            fl.bytes[dir] += (u64)dlen;
            if (PlainPort(rport))
                LogLine("TCP %s %s %d바이트: %s", arrow, peer.c_str(), dlen, Printable(data, dlen, 4000).c_str());
            else if (first)
                LogLine("TCP %s %s %d바이트(암호 · 이진 — 앞부분 %s)", arrow, peer.c_str(), dlen, Hex(data, std::min(dlen, 8)).c_str());
        }
    }
    if (flags & 0x05)   // FIN · RST
    {
        u64 b0 = it != g_Tcp.end() ? it->second.bytes[0] : 0, b1 = it != g_Tcp.end() ? it->second.bytes[1] : 0;
        LogLine("TCP %s %s %s (지금까지 보냄 %llu · 받음 %llu바이트)", arrow, peer.c_str(), (flags & 0x04) ? "RST(끊음)" : "FIN(닫음)",
                (unsigned long long)b0, (unsigned long long)b1);
        if (it != g_Tcp.end() && ((flags & 0x04) || ++it->second.fins >= 2)) g_Tcp.erase(it);
    }
}

} // namespace

// ── Platform_Apple.cpp가 부르는 것(에뮬레이션 스레드) ──────────

int DuoNet_Send(const u8* data, int len)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    if (!g_Net) return len;   // 인터넷 끔 — 버린다(게임에는 접속 실패로 보인다)
    g_Status.bytes_out += len;
    if (IsDnsQuery(data, len)) ForwardDns(data, len);
    else
    {
        Inspect(data, len, true);
        g_Net->SendPacket(const_cast<u8*>(data), len, 0);
    }
    return len;
}

int DuoNet_Recv(u8* data)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    if (!g_Net) return 0;
    PollDns();
    int n = g_Net->RecvPacket(data, 0);
    if (n > 0)
    {
        g_Status.bytes_in += n;
        Inspect(data, n, false);
    }
    return n;
}

// ── C 인터페이스 ─────────────────────────────────

extern "C" {

int ds_net_set_server(const char* dns)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    if (!dns || !*dns)
    {
        DropPending();
        g_Net.reset();
        if (g_Status.enabled) LogLine("── 인터넷 끔 ──");
        g_Status.enabled = 0;
        g_Status.dns = 0;
        return 0;
    }
    in_addr a{};
    if (inet_pton(AF_INET, dns, &a) != 1 || a.s_addr == 0 || a.s_addr == INADDR_BROADCAST) return -1;
    if (!g_Net)
    {
        g_Net = std::make_unique<Net>();
        g_Net->RegisterInstance(0);
        // slirp가 내보내는 프레임은 RecvCheck 안(이미 잠근 채)에서 온다
        g_Net->SetDriver(std::make_unique<Net_Slirp>([](const u8* data, int len) { g_Net->RXEnqueue(data, len); }));
    }
    if (!g_Status.enabled || g_Status.dns != a.s_addr) LogLine("── 인터넷 켬: 서버 DNS %s ──", dns);
    g_Status.enabled = 1;
    g_Status.dns = a.s_addr;
    return 0;
}

void ds_net_set_log(const char* path)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    if (g_Log) fclose(g_Log);
    g_Log = nullptr;
    if (!path || !*path) return;
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > kLogMax) rename(path, (std::string(path) + ".old").c_str());
    g_Log = fopen(path, "a");
    if (!g_Log) return;
    time_t now = time(nullptr);
    tm t;
    localtime_r(&now, &t);
    fprintf(g_Log, "\n════ %04d-%02d-%02d 기록 시작 ════\n", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday);
    fflush(g_Log);
    if (g_Status.enabled) LogLine("── 인터넷 켬: 서버 DNS %s ──", IpText(g_Status.dns).c_str());
}

void ds_net_log_note(const char* text)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    g_Tcp.clear();
    g_UdpSeen.clear();
    LogLine("── %s ──", text);
}

void ds_net_clear_log(void)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    if (!g_Log) return;
    fflush(g_Log);
    if (ftruncate(fileno(g_Log), 0) == 0) fseek(g_Log, 0, SEEK_SET);
}

void ds_net_status(DSNetStatus* out)
{
    std::lock_guard<std::mutex> lk(g_Lock);
    *out = g_Status;
}

int ds_net_probe(const char* dns, const char* name, char* out, int outlen, int timeout_ms)
{
    if (out && outlen > 0) out[0] = 0;
    in_addr a{};
    if (!dns || inet_pton(AF_INET, dns, &a) != 1) return -1;
    u8 q[300];
    u16 id = (u16)(NowMS() * 2654435761u >> 7);
    int qlen = BuildQuery(name, id, q, sizeof(q));
    if (qlen < 0) return -1;
    int fd = SendToDns(a.s_addr, q, qlen);
    if (fd < 0) return -2;

    u64 deadline = NowMS() + (u64)timeout_ms;
    int result = -3;
    while (result == -3)
    {
        u64 now = NowMS();
        if (now >= deadline) break;
        pollfd pfd{fd, POLLIN, 0};
        if (poll(&pfd, 1, (int)(deadline - now)) <= 0) break;
        u8 msg[1472];
        ssize_t n = recv(fd, msg, sizeof(msg), 0);
        if (n < 12 || Read16(msg) != id) continue;   // 다른 답 · 깨진 답은 넘긴다
        u32 addr = FirstA(msg, (int)n);
        if (!addr) { result = -4; break; }
        if (out) inet_ntop(AF_INET, &addr, out, (socklen_t)outlen);
        result = 0;
    }
    close(fd);
    return result;
}

int ds_net_send_frame(const uint8_t* frame, int len) { return DuoNet_Send(frame, len); }
int ds_net_recv_frame(uint8_t* frame) { return DuoNet_Recv(frame); }

}
