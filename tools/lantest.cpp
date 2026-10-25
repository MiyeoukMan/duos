// lantest — 근거리 무선(LAN) 연결만 화면 없이 시험한다(게임 없이 방 만들기 · 참가 · 참가자 목록).
//   lantest host 이름 [초] [최대인원]      방을 만들고 참가자 목록을 1초마다 찍는다
//   lantest join 이름 주소 [초]             주소(IP)의 방에 참가해 목록을 찍는다

#include "DSCore.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

static void PrintPlayers(const char* who)
{
    DSLanPlayer p[16];
    int n = ds_lan_players(p, 16);
    printf("[%s] 상태 %d · %d/%d명:", who, ds_lan_state(), n, ds_lan_max_players());
    for (int i = 0; i < n; i++)
        printf(" #%d %s(%s%s, %ums)", p[i].id, p[i].name, p[i].status == 2 ? "방장" : p[i].status == 1 ? "참가" : p[i].status == 3 ? "연결 중" : "끊김",
               p[i].is_local ? " · 나" : "", p[i].ping_ms);
    printf("\n");
    fflush(stdout);
}

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: lantest host NAME [secs] [max] | join NAME ADDR [secs]\n"); return 2; }
    ds_set_log_handler([](int, const char*) {});
    std::string mode = argv[1];
    int secs = 10;
    if (mode == "host")
    {
        if (argc > 3) secs = atoi(argv[3]);
        int maxp = argc > 4 ? atoi(argv[4]) : 4;
        if (ds_lan_host(argv[2], maxp) != 0) { printf("방 만들기 실패\n"); return 1; }
        printf("방 만듦\n");
    }
    else if (mode == "join" && argc > 3)
    {
        if (argc > 4) secs = atoi(argv[4]);
        int r = ds_lan_join(argv[2], argv[3]);
        if (r != 0) { printf("참가 실패(%d)\n", r); return 1; }
        printf("참가함\n");
    }
    else return 2;

    auto start = std::chrono::steady_clock::now();
    auto last = start;
    while (std::chrono::steady_clock::now() - start < std::chrono::seconds(secs))
    {
        ds_lan_process();
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
        if (std::chrono::steady_clock::now() - last >= std::chrono::seconds(1))
        {
            last = std::chrono::steady_clock::now();
            PrintPlayers(argv[2]);
        }
    }
    ds_lan_leave();
    return 0;
}
