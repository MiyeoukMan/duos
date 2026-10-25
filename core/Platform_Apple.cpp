// Platform_Apple.cpp — melonDS의 Platform 인터페이스를 macOS · iOS용으로 채운다.
// 파일은 stdio, 스레드 · 세마포어는 std::thread · 조건 변수, 시간은 mach_absolute_time.
// 세이브 · 마이크처럼 인스턴스마다 다른 것은 userdata(= DSCore)로 넘긴다 — DSCore.cpp의 DSCore_* 함수.

#include "Platform.h"
#include "SPI_Firmware.h"
#include "MPInterface.h"

#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach/mach_time.h>

// DSCore.cpp에 있다
void DSCore_WriteNDSSave(void* userdata, const melonDS::u8* data, melonDS::u32 len, melonDS::u32 offset, melonDS::u32 writelen);
void DSCore_SignalStop(void* userdata, int reason);
int DSCore_MicRead(void* userdata, melonDS::s16* data, int maxlength);
std::recursive_mutex& DSCore_LanLock();
const char* DSCore_LocalDir();
void DSCore_Log(int level, const char* text);
void DSCore_WriteFirmware(const melonDS::Firmware& fw, melonDS::u32 offset, melonDS::u32 len);
// DuoNet.cpp에 있다
int DuoNet_Send(const melonDS::u8* data, int len);
int DuoNet_Recv(melonDS::u8* data);

namespace melonDS::Platform
{

void SignalStop(StopReason reason, void* userdata)
{
    DSCore_SignalStop(userdata, (int)reason);
}

// ── 파일 ─────────────────────────────────────────────

static std::string ModeString(FileMode mode, bool exists)
{
    std::string m;
    if (mode & FileMode::Append)
        m = "a";
    else if (!(mode & FileMode::Write))
        m = "r";
    else if (mode & (FileMode::NoCreate | FileMode::Preserve))
        m = exists ? "r" : "w";   // 있으면 지우지 않고 연다(아래 '+'로 쓰기 허용)
    else
        m = "w";
    if ((mode & FileMode::ReadWrite) == FileMode::ReadWrite || ((mode & FileMode::Write) && m == "r"))
        m += '+';
    if (!(mode & FileMode::Text))
        m += 'b';
    return m;
}

std::string GetLocalFilePath(const std::string& filename)
{
    if (!filename.empty() && filename[0] == '/') return filename;
    std::string dir = DSCore_LocalDir();
    if (!dir.empty() && dir.back() != '/') dir += '/';
    return dir + filename;
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if ((mode & (FileMode::ReadWrite | FileMode::Append)) == FileMode::None) return nullptr;
    struct stat st;
    bool exists = stat(path.c_str(), &st) == 0;
    if ((mode & FileMode::NoCreate) && !exists) return nullptr;
    FILE* f = fopen(path.c_str(), ModeString(mode, exists).c_str());
    return reinterpret_cast<FileHandle*>(f);
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(GetLocalFilePath(path), mode);
}

bool FileExists(const std::string& name)
{
    struct stat st;
    return stat(name.c_str(), &st) == 0;
}

bool LocalFileExists(const std::string& name)
{
    return FileExists(GetLocalFilePath(name));
}

bool CheckFileWritable(const std::string& filepath)
{
    if (FileExists(filepath)) return access(filepath.c_str(), W_OK) == 0;
    std::string dir = filepath.substr(0, filepath.find_last_of('/'));
    return access(dir.empty() ? "." : dir.c_str(), W_OK) == 0;
}

bool CheckLocalFileWritable(const std::string& filepath)
{
    return CheckFileWritable(GetLocalFilePath(filepath));
}

bool CloseFile(FileHandle* file) { return fclose(reinterpret_cast<FILE*>(file)) == 0; }
bool IsEndOfFile(FileHandle* file) { return feof(reinterpret_cast<FILE*>(file)) != 0; }
bool FileReadLine(char* str, int count, FileHandle* file) { return fgets(str, count, reinterpret_cast<FILE*>(file)) != nullptr; }
u64 FilePosition(FileHandle* file) { return (u64)ftello(reinterpret_cast<FILE*>(file)); }

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int w = origin == FileSeekOrigin::Start ? SEEK_SET : origin == FileSeekOrigin::Current ? SEEK_CUR : SEEK_END;
    return fseeko(reinterpret_cast<FILE*>(file), offset, w) == 0;
}

void FileRewind(FileHandle* file) { rewind(reinterpret_cast<FILE*>(file)); }
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file) { return fread(data, size, count, reinterpret_cast<FILE*>(file)); }
bool FileFlush(FileHandle* file) { return fflush(reinterpret_cast<FILE*>(file)) == 0; }
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file) { return fwrite(data, size, count, reinterpret_cast<FILE*>(file)); }

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    int n = vfprintf(reinterpret_cast<FILE*>(file), fmt, args);
    va_end(args);
    return n < 0 ? 0 : (u64)n;
}

u64 FileLength(FileHandle* file)
{
    FILE* f = reinterpret_cast<FILE*>(file);
    off_t pos = ftello(f);
    fseeko(f, 0, SEEK_END);
    off_t len = ftello(f);
    fseeko(f, pos, SEEK_SET);
    return (u64)len;
}

// ── 로그 ─────────────────────────────────────────────

void Log(LogLevel level, const char* fmt, ...)
{
    if (level == LogLevel::Debug) return;
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    DSCore_Log((int)level, buf);
}

// ── 스레드 · 동기화 ───────────────────────────────────

struct Thread { std::thread t; };

Thread* Thread_Create(std::function<void()> func)
{
    return new Thread{ std::thread(std::move(func)) };
}

void Thread_Free(Thread* thread)
{
    if (thread->t.joinable()) thread->t.detach();
    delete thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread->t.joinable()) thread->t.join();
}

// 세마포어: Reset(개수를 0으로)이 필요해서 dispatch_semaphore 대신 개수를 직접 센다.
struct Semaphore
{
    std::mutex m;
    std::condition_variable cv;
    int count = 0;
};

Semaphore* Semaphore_Create() { return new Semaphore(); }
void Semaphore_Free(Semaphore* sema) { delete sema; }

void Semaphore_Reset(Semaphore* sema)
{
    std::lock_guard<std::mutex> lk(sema->m);
    sema->count = 0;
}

void Semaphore_Wait(Semaphore* sema)
{
    std::unique_lock<std::mutex> lk(sema->m);
    sema->cv.wait(lk, [sema] { return sema->count > 0; });
    sema->count--;
}

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    std::unique_lock<std::mutex> lk(sema->m);
    if (timeout_ms == 0)
    {
        if (sema->count <= 0) return false;
        sema->count--;
        return true;
    }
    if (!sema->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms), [sema] { return sema->count > 0; })) return false;
    sema->count--;
    return true;
}

void Semaphore_Post(Semaphore* sema, int count)
{
    {
        std::lock_guard<std::mutex> lk(sema->m);
        sema->count += count;
    }
    if (count == 1) sema->cv.notify_one(); else sema->cv.notify_all();
}

struct Mutex { std::mutex m; };

Mutex* Mutex_Create() { return new Mutex(); }
void Mutex_Free(Mutex* mutex) { delete mutex; }
void Mutex_Lock(Mutex* mutex) { mutex->m.lock(); }
void Mutex_Unlock(Mutex* mutex) { mutex->m.unlock(); }
bool Mutex_TryLock(Mutex* mutex) { return mutex->m.try_lock(); }

void Sleep(u64 usecs) { usleep((useconds_t)usecs); }

static u64 NowNanos()
{
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return mach_absolute_time() * tb.numer / tb.denom;
}

u64 GetMSCount() { return NowNanos() / 1000000ull; }
u64 GetUSCount() { return NowNanos() / 1000ull; }

// ── 세이브 · 펌웨어 · 시계 ─────────────────────────────

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    DSCore_WriteNDSSave(userdata, savedata, savelen, writeoffset, writelen);
}

void WriteGBASave(const u8*, u32, u32, u32, void*) {}
// 펌웨어는 켤 때마다 새로 만든다 — 남기는 것은 게임이 쓴 Nintendo WFC 설정(접속 ID · 접속점)뿐
void WriteFirmware(const Firmware& fw, u32 offset, u32 len, void*) { DSCore_WriteFirmware(fw, offset, len); }
void WriteDateTime(int, int, int, int, int, int, void*) {}  // 시계는 켤 때마다 기기 시각으로 맞춘다

// ── 근거리 무선(DS끼리) → melonDS LAN(ENet, UDP) ─────────
// 이 앱은 에뮬레이터가 하나뿐이라 인스턴스 번호는 늘 0. 앱 쪽(방 만들기 · 참가)과 겹치지 않게 DSCore의 잠금 아래서.

#define MP_CALL(expr) do { std::lock_guard<std::recursive_mutex> lk(DSCore_LanLock()); expr; } while (0)

void MP_Begin(void*) { MP_CALL(MPInterface::Get().Begin(0)); }
void MP_End(void*) { MP_CALL(MPInterface::Get().End(0)); }
int MP_SendPacket(u8* data, int len, u64 ts, void*) { int r = 0; MP_CALL(r = MPInterface::Get().SendPacket(0, data, len, ts)); return r; }
int MP_RecvPacket(u8* data, u64* ts, void*) { int r = 0; MP_CALL(r = MPInterface::Get().RecvPacket(0, data, ts)); return r; }
int MP_SendCmd(u8* data, int len, u64 ts, void*) { int r = 0; MP_CALL(r = MPInterface::Get().SendCmd(0, data, len, ts)); return r; }
int MP_SendReply(u8* data, int len, u64 ts, u16 aid, void*) { int r = 0; MP_CALL(r = MPInterface::Get().SendReply(0, data, len, ts, aid)); return r; }
int MP_SendAck(u8* data, int len, u64 ts, void*) { int r = 0; MP_CALL(r = MPInterface::Get().SendAck(0, data, len, ts)); return r; }
int MP_RecvHostPacket(u8* data, u64* ts, void*) { int r = 0; MP_CALL(r = MPInterface::Get().RecvHostPacket(0, data, ts)); return r; }
u16 MP_RecvReplies(u8* data, u64 ts, u16 aidmask, void*) { u16 r = 0; MP_CALL(r = MPInterface::Get().RecvReplies(0, data, ts, aidmask)); return r; }

// ── 인터넷(가상 공유기 뒤) → libslirp · 사설 서버 DNS — DuoNet.cpp ──

int Net_SendPacket(u8* data, int len, void*) { return DuoNet_Send(data, len); }
int Net_RecvPacket(u8* data, void*) { return DuoNet_Recv(data); }

// ── 카메라 · 마이크 ───────────────────────────────────

void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32* frame, int width, int height, bool, void*)
{
    memset(frame, 0, (size_t)width * height * sizeof(u32));
}

void Mic_Start(void*) {}
void Mic_Stop(void*) {}
int Mic_ReadInput(s16* data, int maxlength, void* userdata) { return DSCore_MicRead(userdata, data, maxlength); }

// ── DSi 전용(쓰지 않음) ────────────────────────────────

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

// ── 확장 기기 ─────────────────────────────────────────

bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType type, void*) { return type == MotionAccelerationZ ? 9.80665f : 0.f; }

// ── 동적 라이브러리 ───────────────────────────────────

DynamicLibrary* DynamicLibrary_Load(const char* lib) { return reinterpret_cast<DynamicLibrary*>(dlopen(lib, RTLD_NOW | RTLD_LOCAL)); }
void DynamicLibrary_Unload(DynamicLibrary* lib) { dlclose(lib); }
void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name) { return dlsym(lib, name); }

}
