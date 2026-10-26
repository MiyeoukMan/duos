// DSCore.h — melonDS 코어를 감싼 C 인터페이스. Swift(브리징 헤더)와 화면 없는 실행기(tools/dsrun)가 같이 쓴다.
// 스레드: 한 코어는 한 스레드에서만 부른다(앱은 에뮬레이션 스레드). 예외는 ds_set_* 입력 함수 — 아무 스레드에서나 불러도 된다.

#ifndef DSCORE_H
#define DSCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DSCore DSCore;

// 버튼(누르면 1). melonDS 키 마스크와 같은 순서.
enum
{
    DS_KEY_A      = 1 << 0,
    DS_KEY_B      = 1 << 1,
    DS_KEY_SELECT = 1 << 2,
    DS_KEY_START  = 1 << 3,
    DS_KEY_RIGHT  = 1 << 4,
    DS_KEY_LEFT   = 1 << 5,
    DS_KEY_UP     = 1 << 6,
    DS_KEY_DOWN   = 1 << 7,
    DS_KEY_R      = 1 << 8,
    DS_KEY_L      = 1 << 9,
    DS_KEY_X      = 1 << 10,
    DS_KEY_Y      = 1 << 11,
};

enum
{
    DS_SCREEN_WIDTH = 256,
    DS_SCREEN_HEIGHT = 192,
    DS_AUDIO_RATE = 48000,
};

// 펌웨어 언어(DS 본체 설정)
enum
{
    DS_LANG_JAPANESE = 0,
    DS_LANG_ENGLISH = 1,
    DS_LANG_FRENCH = 2,
    DS_LANG_GERMAN = 3,
    DS_LANG_ITALIAN = 4,
    DS_LANG_SPANISH = 5,
};

typedef struct
{
    const char* nickname;   // UTF-8, 최대 10글자
    int language;           // DS_LANG_*
    int favorite_color;     // 0~15
    int birthday_month;     // 1~12
    int birthday_day;       // 1~31
} DSFirmwareUser;

// 코어가 남기는 글(경고 · 오류)을 받을 곳 — 프로세스에 하나. NULL이면 stderr.
void ds_set_log_handler(void (*handler)(int level, const char* text));
// melonDS가 쓰는 보조 파일(DLDI SD 이미지 등)을 둘 폴더 — 프로세스에 하나.
void ds_set_local_dir(const char* path);

DSCore* ds_create(void);
void ds_destroy(DSCore* core);

void ds_set_firmware_user(DSCore* core, const DSFirmwareUser* user);   // 다음 ds_load_rom부터

// ROM을 넣고 켠다. save_path의 파일이 있으면 읽고, 게임이 저장하면 그 경로에 쓴다(ds_flush_save · 자동 1초 뒤).
// 0 = 성공. 실패하면 err에 이유.
int ds_load_rom(DSCore* core, const char* rom_path, const char* save_path, char* err, int errlen);
void ds_reset(DSCore* core);
int ds_is_running(DSCore* core);   // 게임이 스스로 꺼지면(전원 끄기) 0

void ds_set_keys(DSCore* core, uint32_t pressed);   // DS_KEY_* 비트
void ds_set_touch(DSCore* core, int touching, int x, int y);   // 아래 화면 좌표(0~255, 0~191)
void ds_set_lid_closed(DSCore* core, int closed);   // 접기 = DS 뚜껑 닫기(대부분 게임은 절전, 여는 순간 깨어남)
int ds_is_asleep(DSCore* core);                     // 게임이 절전에 들어가 있으면 1(에뮬레이션 스레드에서)
void ds_set_mic_blow(DSCore* core, int blowing);   // 마이크에 바람 부는 소리를 넣는다

// 한 프레임(1/59.83초)을 돌린다. 끝나면 화면 · 소리가 새로 생긴다.
void ds_run_frame(DSCore* core);
// 화면 두 장(BGRA 8비트, 256 × 192). 다음 ds_run_frame 전까지 유효.
const uint32_t* ds_screen(DSCore* core, int bottom);
// 소리(48 kHz 스테레오 16비트, 왼 · 오 번갈아). 돌려준 값은 프레임(쌍) 수.
int ds_read_audio(DSCore* core, int16_t* out, int max_frames);

// 3D 내부 해상도(1~4배) — 아무 스레드에서나, 다음 프레임부터. 1 = melonDS 소프트웨어 렌더러 그대로,
// 2~4 = 3D만 Metal로 높은 해상도에 그린다(2D · 화면 캡처는 그대로 256 × 192). Metal을 못 쓰면 1로 돌아간다.
void ds_set_3d_scale(DSCore* core, int scale);
int ds_3d_scale(DSCore* core);   // 지금 쓰는 배율(에뮬레이션 스레드에서)
// 이 프레임에 3D가 있던 화면의 고해상도 그림(id<MTLTexture>, BGRA 8비트, (256 × 배율) × (192 × 배율)) — 없으면 NULL.
// 앱 쪽 Metal 장치(MTLCreateSystemDefaultDevice)와 같은 장치. 다음다음 ds_run_frame까지 그대로 있다.
void* ds_screen_texture(DSCore* core, int bottom, int* width, int* height);
// 같은 그림을 CPU로(BGRA 메모리 = 0xAARRGGBB) — 시험 도구용. 픽셀 수를 돌려준다(없으면 0). out은 max_pixels 이상
int ds_screen_hires(DSCore* core, int bottom, uint32_t* out, int max_pixels, int* width, int* height);

// DS 무선 주소(MAC). 기기마다 달라야 근거리 통신에서 서로를 구분한다 — 다음 ds_load_rom부터.
void ds_set_mac(DSCore* core, const uint8_t mac[6]);

int ds_flush_save(DSCore* core);   // 바뀐 세이브를 지금 쓴다. 1 = 썼음
int ds_save_state(DSCore* core, const char* path);   // 0 = 성공
int ds_load_state(DSCore* core, const char* path);   // 0 = 성공

// ── 근거리 무선(DS끼리 — melonDS LAN, UDP 7064) ── 프로세스에 하나. 아무 스레드에서나(안에서 잠근다).
// 방은 게임을 켜기 전에 만들어도 되고, 게임 안의 통신 메뉴가 이 연결을 쓴다. 모두 같은 게임을 꽂아야 한다.

enum
{
    DS_LAN_NONE = 0,
    DS_LAN_HOST = 1,
    DS_LAN_CLIENT = 2,
};

typedef struct
{
    int id;
    char name[32];
    int status;          // 1 참가자 · 2 방장 · 3 연결 중 · 4 끊김
    uint32_t address;    // IPv4(네트워크 순서)
    int is_local;
    uint32_t ping_ms;
} DSLanPlayer;

int ds_lan_host(const char* player, int max_players);          // 0 = 성공
int ds_lan_join(const char* player, const char* host);         // 최대 5초 기다린다. 0 = 성공
void ds_lan_leave(void);
int ds_lan_state(void);                                        // DS_LAN_*
int ds_lan_players(DSLanPlayer* out, int max);                 // 사람 수
int ds_lan_max_players(void);
void ds_lan_process(void);                                     // 자주(초당 수십 번) 불러 연결을 돌본다

// ── 인터넷(Nintendo WFC 대체 서버 — Wiimmfi 등) ── 프로세스에 하나. 아무 스레드에서나(안에서 잠근다).
// 게임은 펌웨어에 잡힌 가상 공유기(melonAP)에 붙고, 그 뒤는 libslirp가 이 기기의 인터넷으로 잇는다.
// 게임의 DNS 질의(UDP 53)는 어느 주소로 가든 고른 서버의 DNS로 넘긴다 — nintendowifi.net이 그 서버를 가리키게.
// Nintendo WFC 설정(접속 ID · 접속 설정)은 게임이 펌웨어에 쓰면 로컬 폴더의 wfcsettings.bin에 남고, 다음 켤 때 되살린다.

typedef struct
{
    int enabled;
    uint32_t dns;                 // 서버 DNS(IPv4, 네트워크 순서)
    uint32_t dns_queries;         // 게임이 물은 수
    uint32_t dns_answers;         // 서버가 답한 수
    uint32_t dns_failures;        // 답이 없던 수(4초)
    uint64_t bytes_out;           // 게임 → 인터넷(이더넷 프레임 바이트)
    uint64_t bytes_in;            // 인터넷 → 게임
    char last_name[64];           // 게임이 마지막으로 물은 이름
    uint32_t last_address;        // 그 답(IPv4, 네트워크 순서) — 0 = 아직 · 실패
} DSNetStatus;

int ds_net_set_server(const char* dns);    // 서버 DNS(IPv4 글자). NULL · "" = 인터넷 끔. 0 = 성공, -1 = 주소가 틀림
void ds_net_status(DSNetStatus* out);
// 서버 DNS에 name을 직접 물어 첫 IPv4를 out에(글자). 최대 timeout_ms 기다린다(부른 스레드를 막는다). 0 = 성공
int ds_net_probe(const char* dns, const char* name, char* out, int outlen, int timeout_ms);
// 접속 기록(원인 찾기): DHCP · DNS · TCP 연결 · 암호 없는 로그인 메시지(GameSpy 29900/29901 · HTTP 80)를 path에 덧붙여 쓴다.
// 512KB를 넘으면 path.old로 옮기고 새로. NULL = 끔. note는 구분 줄(예: 게임을 켰다)
void ds_net_set_log(const char* path);
void ds_net_log_note(const char* text);
void ds_net_clear_log(void);
int ds_wfc_reset(void);                    // wfcsettings.bin을 지운다(다음 켤 때 새 접속 ID) — 게임이 꺼져 있을 때. 0 = 지움/없음
int ds_wfc_configured(void);               // 이 기기에 저장된 Nintendo WFC 접속 ID가 있으면 1

// 시험용(tools/nettest): 게임 대신 이더넷 프레임을 가상 공유기 뒤로 보내고 받는다
int ds_net_send_frame(const uint8_t* frame, int len);
int ds_net_recv_frame(uint8_t* frame);     // 받은 길이(없으면 0). frame은 2048바이트 이상

#ifdef __cplusplus
}
#endif

#endif
