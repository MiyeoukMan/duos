#!/usr/bin/env python3
"""시험 ROM(tools/testrom/*.c)을 DS ROM 한 개로 만든다.

Xcode의 clang은 ARM 목적 파일(ELF)까지는 만들지만 링커(ld.lld)가 없다 → 여기 작은 링커로 섹션을 잇고
재배치(R_ARM_ABS32 · CALL · JUMP24 · REL32)를 푼다. 닌텐도 로고 · 시큐어 영역 없이 홈브루 헤더만 쓴다.

    python3 tools/mkrom.py build/test.nds
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "testrom")

ARM9_BASE = 0x02000000
ARM7_BASE = 0x03800000


def compile_c(src, obj, cpu, defines=()):
    subprocess.check_call([
        "xcrun", "clang", "-target", "armv5te-none-eabi" if cpu == "arm9" else "armv4t-none-eabi",
        "-marm", "-mfloat-abi=soft", "-ffreestanding", "-nostdlib", "-fno-builtin", "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables", "-fno-exceptions", "-O2", "-Wall", *[f"-D{d}" for d in defines], "-c", src, "-o", obj,
    ])


def link(obj, base):
    data = open(obj, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise SystemExit(f"{obj}: not a 32-bit little-endian ELF")
    e_shoff, = struct.unpack_from("<I", data, 0x20)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x2E)
    secs = []
    for i in range(e_shnum):
        name, typ, flags, addr, off, size, link_, info, align, entsize = struct.unpack_from("<10I", data, e_shoff + i * e_shentsize)
        secs.append(dict(name=name, type=typ, flags=flags, off=off, size=size, link=link_, info=info, align=max(align, 1), entsize=entsize))
    shstr = secs[e_shstrndx]

    def cstr(off):
        end = data.index(b"\0", off)
        return data[off:end].decode()

    for s in secs:
        s["sname"] = cstr(shstr["off"] + s["name"])

    # 실을 섹션: 진입점 먼저, 그다음 코드 · 읽기 전용 · 데이터 · bss
    def rank(s):
        n = s["sname"]
        if n == ".text.entry":
            return 0
        if n.startswith(".text"):
            return 1
        if n.startswith(".rodata"):
            return 2
        if s["type"] == 8:
            return 4
        return 3

    alloc = [i for i, s in enumerate(secs) if s["flags"] & 2 and not s["sname"].startswith(".ARM.")]
    alloc.sort(key=lambda i: rank(secs[i]))
    image = bytearray()
    for i in alloc:
        s = secs[i]
        while len(image) % s["align"]:
            image.append(0)
        s["addr"] = base + len(image)
        image += b"\0" * s["size"] if s["type"] == 8 else data[s["off"]:s["off"] + s["size"]]
    while len(image) % 4:
        image.append(0)

    symtab = next(s for s in secs if s["type"] == 2)
    strtab = secs[symtab["link"]]
    syms = []
    for k in range(symtab["size"] // 16):
        st_name, st_value, st_size, st_info, st_other, st_shndx = struct.unpack_from("<IIIBBH", data, symtab["off"] + k * 16)
        name = cstr(strtab["off"] + st_name)
        if st_shndx == 0:
            syms.append((name, None))
        elif st_shndx < len(secs) and "addr" in secs[st_shndx]:
            syms.append((name, secs[st_shndx]["addr"] + st_value))
        else:
            syms.append((name, st_value))

    for rs in secs:
        if rs["type"] != 9:   # SHT_REL
            continue
        target = secs[rs["info"]]
        if "addr" not in target:
            continue
        for k in range(rs["size"] // 8):
            r_off, r_info = struct.unpack_from("<II", data, rs["off"] + k * 8)
            typ, symi = r_info & 0xFF, r_info >> 8
            name, S = syms[symi]
            if S is None:
                raise SystemExit(f"undefined symbol: {name}")
            P = target["addr"] + r_off
            at = P - base
            word, = struct.unpack_from("<I", image, at)
            if typ in (0, 40):        # NONE, V4BX
                continue
            if typ == 2:              # ABS32
                val = (S + word) & 0xFFFFFFFF
            elif typ == 3:            # REL32
                val = (S + word - P) & 0xFFFFFFFF
            elif typ in (28, 29):     # CALL, JUMP24
                A = ((word & 0xFFFFFF) ^ 0x800000) - 0x800000
                off = (S + (A << 2) - P) >> 2
                val = (word & 0xFF000000) | (off & 0xFFFFFF)
            else:
                raise SystemExit(f"unsupported relocation type {typ} for {name}")
            struct.pack_into("<I", image, at, val)
    return bytes(image)


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


# ── 배너(목록 · 카트리지 라벨에 보이는 아이콘 · 제목) — 아이콘은 직접 그린 32 × 32 픽셀 그림 ──

def _icon(kind):
    """32 × 32 팔레트 번호 그림과 16색 팔레트(BGR555)를 돌려준다. 0번 = 투명."""
    import math
    def rgb(r, g, b):
        return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
    pal = [0] * 16
    px = [[0] * 32 for _ in range(32)]

    def inside(x, y):
        u, v = (x - 15.5) / 13.0, (15.5 - y) / 13.0
        if kind == "heart":
            u, v = u * 1.15, v * 1.15 + 0.15
            return (u * u + v * v - 1) ** 3 - u * u * v ** 3 <= 0
        if kind == "star":
            a = math.atan2(v, u) - math.pi / 2
            rr = math.hypot(u, v)
            k = (a % (2 * math.pi / 5)) / (2 * math.pi / 5)
            lim = 0.48 + 0.52 * abs(1 - 2 * k) ** 1.6
            return rr <= lim
        if kind == "slime":
            return v <= 0.55 - 0.9 * u * u and v >= -0.75 and abs(u) <= 0.95
        if kind == "rocket":
            body = abs(u) <= 0.32 * math.sqrt(max(0, 1 - ((v - 0.05) / 0.85) ** 2)) * 1.35
            fins = v <= -0.35 and v >= -0.8 and abs(u) <= 0.62 - (v + 0.8) * 0.5
            return body or fins
        return False

    base = {"heart": (232, 52, 76), "star": (255, 204, 40), "slime": (84, 200, 96), "rocket": (236, 238, 244)}[kind]
    pal[1] = rgb(34, 30, 46)
    pal[2] = rgb(*base)
    pal[3] = rgb(*(max(0, c - 70) for c in base))
    pal[4] = rgb(*(min(255, c + 70) for c in base))
    pal[5] = rgb(255, 255, 255)
    pal[6] = rgb(30, 30, 40)
    pal[7] = rgb(250, 120, 40)
    pal[8] = rgb(90, 170, 255)
    pal[9] = rgb(220, 50, 60)
    mask = [[inside(x, y) for x in range(32)] for y in range(32)]
    for y in range(32):
        for x in range(32):
            if mask[y][x]:
                u, v = (x - 15.5) / 13.0, (15.5 - y) / 13.0
                px[y][x] = 4 if (u + v) > 0.55 else 3 if (u + v) < -0.45 else 2
            elif any(0 <= x + dx < 32 and 0 <= y + dy < 32 and mask[y + dy][x + dx] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                px[y][x] = 1
    if kind == "slime":
        for ex in (11, 19):
            for y in range(15, 20):
                for x in range(ex - 1, ex + 2):
                    px[y][x] = 6
            px[15][ex] = 5
    if kind == "rocket":
        for y in range(9, 15):
            for x in range(13, 19):
                if (x - 15.5) ** 2 + (y - 11.5) ** 2 <= 7:
                    px[y][x] = 8
        for x in range(4, 28):
            for y in range(19, 21):
                if px[y][x] in (2, 3, 4):
                    px[y][x] = 9
        for y in range(27, 32):
            for x in range(13, 19):
                if px[y][x] == 0 and abs(x - 15.5) <= (32 - y) * 0.7:
                    px[y][x] = 7
    if kind in ("heart", "star"):
        px[9][10] = px[9][11] = px[10][10] = 5
    return px, pal


def make_banner(titles, kind):
    """3판 배너(0xA40 바이트): 판 · CRC · 아이콘 · 팔레트 · 언어별 제목(일 · 영 · 프 · 독 · 이 · 스 · 중 · 한)."""
    b = bytearray(0xA40)
    struct.pack_into("<H", b, 0, 3)
    px, pal = _icon(kind)
    for tile in range(16):
        tx, ty = (tile % 4) * 8, (tile // 4) * 8
        for i in range(32):
            x, y = tx + (i % 4) * 2, ty + i // 4
            b[0x20 + tile * 32 + i] = px[y][x] | (px[y][x + 1] << 4)
    for i, c in enumerate(pal):
        struct.pack_into("<H", b, 0x220 + i * 2, c)
    for lang in range(8):
        t = titles.get(lang, titles.get(1, "")).encode("utf-16-le")[:0xFE]
        b[0x240 + lang * 0x100:0x240 + lang * 0x100 + len(t)] = t
    struct.pack_into("<H", b, 2, crc16(b[0x20:0x840]))
    struct.pack_into("<H", b, 4, crc16(b[0x20:0x940]))
    struct.pack_into("<H", b, 6, crc16(b[0x20:0xA40]))
    return bytes(b)


def build(out, title=None, code=b"DUOT", icon=None, defines=(), header=b"DUODS TEST"):
    tmp = os.path.join(os.path.dirname(os.path.abspath(out)), "testrom-obj")
    os.makedirs(tmp, exist_ok=True)
    compile_c(os.path.join(SRC, "arm9.c"), os.path.join(tmp, "arm9.o"), "arm9", defines)
    compile_c(os.path.join(SRC, "arm7.c"), os.path.join(tmp, "arm7.o"), "arm7")
    arm9 = link(os.path.join(tmp, "arm9.o"), ARM9_BASE)
    arm7 = link(os.path.join(tmp, "arm7.o"), ARM7_BASE)

    def align(x, a):
        return (x + a - 1) // a * a

    arm9_off = 0x200
    arm7_off = align(arm9_off + len(arm9), 0x200)
    end = align(arm7_off + len(arm7), 0x200)
    banner = None
    banner_off = 0
    if title:
        banner = make_banner(title, icon or "star")
        banner_off = end
        end = align(banner_off + len(banner), 0x200)
    total = max(end, 0x20000)

    rom = bytearray(total)
    h = bytearray(0x200)
    h[0x000:0x00C] = header[:12].ljust(12, b"\0")
    h[0x00C:0x010] = code
    h[0x010:0x012] = b"00"
    struct.pack_into("<IIII", h, 0x20, arm9_off, ARM9_BASE, ARM9_BASE, len(arm9))
    struct.pack_into("<IIII", h, 0x30, arm7_off, ARM7_BASE, ARM7_BASE, len(arm7))
    struct.pack_into("<IIII", h, 0x40, end, 0, end, 0)        # 파일 시스템 없음
    struct.pack_into("<II", h, 0x60, 0x00586000, 0x001808F8)  # 카드 읽기 타이밍(흔한 값)
    struct.pack_into("<I", h, 0x68, banner_off)
    struct.pack_into("<II", h, 0x80, end, 0x4000)
    struct.pack_into("<H", h, 0x15C, crc16(h[0xC0:0x15C]))
    struct.pack_into("<H", h, 0x15E, crc16(h[0:0x15E]))
    rom[0:0x200] = h
    rom[arm9_off:arm9_off + len(arm9)] = arm9
    rom[arm7_off:arm7_off + len(arm7)] = arm7
    if banner:
        rom[banner_off:banner_off + len(banner)] = banner
    with open(out, "wb") as f:
        f.write(rom)
    print(f"{out}: ARM9 {len(arm9)} bytes, ARM7 {len(arm7)} bytes, ROM {len(rom)} bytes")


# 카트리지 라벨 · 목록 시험용 — 같은 시험 프로그램에 배너만 다르게(제목은 지어낸 것)
SHOWCASE = [
    ("star.nds", b"DSTR", "star", {1: "Star Collector\nDuoS Test Lab", 7: "별빛 수집가\nDuoS 시험실"}),
    ("heart.nds", b"DHRT", "heart", {1: "Heart Puzzle\nDuoS Test Lab", 7: "하트 퍼즐\nDuoS 시험실"}),
    ("slime.nds", b"DSLM", "slime", {1: "Slime Adventure\nDuoS Test Lab", 7: "말랑 슬라임 대모험\nDuoS 시험실"}),
    ("rocket.nds", b"DRKT", "rocket", {1: "Rocket Racer\nDuoS Test Lab", 7: "로켓 레이서\nDuoS 시험실"}),
]

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--showcase":
        outdir = sys.argv[2] if len(sys.argv) > 2 else "build/showcase"
        os.makedirs(outdir, exist_ok=True)
        for name, code, icon, titles in SHOWCASE:
            build(os.path.join(outdir, name), titles, code, icon)
    elif len(sys.argv) > 1 and sys.argv[1] == "--demo":
        # 앱에 넣는 데모 카트리지(심사 · 처음 켠 사람용) — 시험 프로그램 그대로: 버튼 · 터치 그림판 · 마이크 · 3D 삼각형 · 소리
        build(sys.argv[2] if len(sys.argv) > 2 else "app/DuoDS/Samples/duos-demo.nds",
              {1: "DuoS Demo\nButtons · Touch · Mic · 3D", 7: "DuoS 데모\n버튼 · 터치 · 마이크 · 3D"}, b"DUOD", "slime", header=b"DUOS DEMO")
    elif len(sys.argv) > 1 and sys.argv[1] == "--scene3d":
        # 3D 시험 장면(텍스처 · 원근 · 반투명 · 안개 · 가장자리) — 3D 내부 해상도 비교용
        build(sys.argv[2] if len(sys.argv) > 2 else "build/scene3d.nds", code=b"DU3D", defines=("SCENE3D",))
    else:
        build(sys.argv[1] if len(sys.argv) > 1 else "build/test.nds")
