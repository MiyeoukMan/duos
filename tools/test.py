#!/usr/bin/env python3
"""코어 시험: 직접 만든 시험 ROM(build/test.nds)을 dsrun으로 돌리고 화면 픽셀 · 소리 세기를 확인한다.

    make test        (= python3 tools/mkrom.py build/test.nds && python3 tools/test.py)
"""
import os
import re
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DSRUN = os.path.join(ROOT, "build/macos/dsrun")
ROM = os.path.join(ROOT, "build/test.nds")
TMP = os.path.join(ROOT, "build/test-out")

KEYS = ["A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L", "X", "Y"]


def run(*args):
    out = subprocess.run([DSRUN, ROM, "--quiet", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError(out.stderr)
    return out.stdout


def png(path):
    data = open(path, "rb").read()
    pos, idat = 8, b""
    while pos < len(data):
        n, = struct.unpack(">I", data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[pos + 8:pos + 16])
        if typ == b"IDAT":
            idat += data[pos + 8:pos + 8 + n]
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 3 + 1
    return lambda x, y: tuple(raw[y * stride + 1 + x * 3:y * stride + 4 + x * 3])


def rms(out):
    return float(re.search(r"rms ([\d.]+)", out).group(1))


def bottom(px, x, y):
    return px(x, 192 + y)


def lit(c):
    return c[0] > 200 and c[1] > 150 and c[2] < 100   # 노란 칸


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("  ok   " if ok else "  FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


def main():
    os.makedirs(TMP, exist_ok=True)
    p = os.path.join(TMP, "boot.png")
    out = run("--frames", "60", "--png", p)
    px = png(p)
    top_colors = {px(x, y) for x in range(0, 256, 8) for y in range(0, 192, 8)}
    check("3D 삼각형이 위 화면에 그려진다", len(top_colors) > 3, str(len(top_colors)))
    check("버튼을 안 누르면 칸이 모두 꺼져 있다", not any(lit(bottom(px, 4 + i * 21 + 9, 11)) for i in range(12)))
    check("소리 없음", rms(out) < 1, str(rms(out)))

    for i, k in enumerate(KEYS):
        p = os.path.join(TMP, f"key-{k}.png")
        run("--frames", "30", "--press", f"10-30:{k}", "--png", p)
        px = png(p)
        on = [j for j in range(12) if lit(bottom(px, 4 + j * 21 + 9, 11))]
        check(f"{k} 누름 → {k} 칸만 켜짐", on == [i], str(on))

    p = os.path.join(TMP, "touch.png")
    run("--frames", "30", "--touch", "10-12:37,150", "--touch", "15-17:200,60", "--png", p)
    px = png(p)
    check("터치 (37,150)에 점", min(bottom(px, 37, 150)) > 240, str(bottom(px, 37, 150)))
    check("터치 (200,60)에 점", min(bottom(px, 200, 60)) > 240, str(bottom(px, 200, 60)))

    p = os.path.join(TMP, "blow.png")
    run("--frames", "40", "--blow", "5-40", "--png", p)
    px = png(p)
    bar = sum(1 for y in range(28, 188) if bottom(px, 252, y)[1] > 200)
    check("마이크에 바람 → 세기 막대가 찬다", bar > 40, f"{bar}px")

    out = run("--frames", "60", "--press", "0-60:A")
    check("A를 누르면 소리가 난다", rms(out) > 1000, str(rms(out)))

    st = os.path.join(TMP, "state.mst")
    a = os.path.join(TMP, "state-a.png")
    b = os.path.join(TMP, "state-b.png")
    run("--frames", "101", "--press", "0-49:RIGHT+UP+X", "--state-save", f"50:{st}", "--png-at", f"100:{a}")
    out = run("--frames", "61", "--state-load", f"10:{st}", "--png-at", f"60:{b}")
    check("상태 불러오기 → 같은 화면", open(a, "rb").read() == open(b, "rb").read(), out.strip())

    # 접기 = 뚜껑 닫기: 게임은 ARM7 KEYXY 비트 7로 안다(시험 ROM은 아래 화면 구석 (238,180)이 빨강)
    def lid_red(path):
        c = bottom(png(path), 241, 183)
        return c[0] > 200 and c[1] < 80
    la, lb, lc = (os.path.join(TMP, n) for n in ("lid-a.png", "lid-b.png", "lid-c.png"))
    lst = os.path.join(TMP, "lid.mst")
    run("--frames", "31", "--lid", "10-40", "--png-at", f"30:{la}", "--state-save", f"30:{lst}")
    check("뚜껑을 닫으면 게임이 안다", lid_red(la))
    run("--frames", "61", "--lid", "10-40", "--png-at", f"60:{lb}")
    check("다시 열면 게임도 열린 것으로 안다", not lid_red(lb))
    sleep_checks()

    hires_checks()

    print(f"{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


# ── 접기 = 뚜껑 닫기: 절전 · 깨우기(mkrom.py --sleeptest — 뚜껑이 닫히면 ARM7이 절전) ──
SLEEPROM = os.path.join(ROOT, "build/sleep.nds")


def asleep(out):
    return [l for l in out.splitlines() if l.startswith("asleep ")][-1] == "asleep 1"


def sleep_checks():
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools/mkrom.py"), "--sleeptest", SLEEPROM], stdout=subprocess.DEVNULL)
    st = os.path.join(TMP, "sleep.mst")
    check("뚜껑을 닫으면 게임이 절전에 든다", asleep(run_rom(SLEEPROM, "--frames", "31", "--lid", "10-40", "--state-save", f"30:{st}")))
    check("뚜껑을 열면 깨어난다", not asleep(run_rom(SLEEPROM, "--frames", "61", "--lid", "10-40")))
    a = os.path.join(TMP, "sleep-a.png")
    out = run_rom(SLEEPROM, "--frames", "41", "--state-load", f"5:{st}", "--press", "20-40:A", "--png-at", f"40:{a}")
    woke = not asleep(out) and lit(bottom(png(a), 4 + 9, 11))
    check("잠든 채 저장한 상태를 불러와 펼치면 깨어나 다시 돈다(앱을 다시 켠 뒤 이어 하기)", woke, out.strip().splitlines()[-1])


# ── 3D 내부 해상도(dsrun --scale) ─────────────────────────────
SCENE = os.path.join(ROOT, "build/scene3d.nds")   # mkrom.py --scene3d: 텍스처 · 원근 · 반투명 · 안개 · 가장자리


def run_rom(rom, *args):
    out = subprocess.run([DSRUN, rom, "--quiet", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError(out.stderr)
    return out.stdout


def png_size(path):
    return struct.unpack(">II", open(path, "rb").read()[16:24])


def compare(a, b, k, screen):
    """1배 그림 a와 k배 그림 b의 한 화면을 블록 가운데 픽셀끼리 — (다른 픽셀 수, 크게(>24) 다른 수)"""
    pa, pb = png(a), png(b)
    diff = big = 0
    for y in range(192 * screen, 192 * (screen + 1)):
        for x in range(256):
            p, q = pa(x, y), pb(x * k + k // 2, y * k + k // 2)
            d = max(abs(p[i] - q[i]) for i in range(3))
            diff += d > 0
            big += d > 24
    return diff, big


def hires_checks():
    if not os.path.exists(SCENE):
        subprocess.check_call([sys.executable, os.path.join(ROOT, "tools/mkrom.py"), "--scene3d", SCENE], stdout=subprocess.DEVNULL)
    one = os.path.join(TMP, "hi-1.png")
    run("--frames", "60", "--png", one)
    two = os.path.join(TMP, "hi-2.png")
    run("--frames", "60", "--scale", "2", "--png", two)
    diff, big = compare(one, two, 2, 0)
    check("3D 2배: 그림이 512 × 768, 삼각형은 1배와 같다(가장자리만 다름)",
          png_size(two) == (512, 768) and big < 400, f"{png_size(two)} 크게 다름 {big}")

    s1, s4 = os.path.join(TMP, "scene-1.png"), os.path.join(TMP, "scene-4.png")
    run_rom(SCENE, "--frames", "40", "--png", s1)
    run_rom(SCENE, "--frames", "40", "--scale", "4", "--png", s4)
    diff, big = compare(s1, s4, 4, 0)
    # 바둑판 텍셀 경계 · 폴리곤 가장자리가 1배와 다른 자리에 떨어지는 것만 다르다(전체의 몇 %)
    check("3D 4배: 시험 장면(텍스처 · 반투명 · 안개 · 가장자리)이 1배와 같은 그림", big < 49152 * 0.08, f"크게 다름 {big}/49152")
    same2d = compare(s1, s4, 4, 1)[0]
    check("3D 4배: 2D만 있는 아래 화면은 1배 그대로", same2d == 0, f"다름 {same2d}")

    sw = os.path.join(TMP, "scene-swap-4.png")
    run_rom(SCENE, "--frames", "40", "--scale", "4", "--press", "30-40:SELECT", "--png", sw)
    sw1 = os.path.join(TMP, "scene-swap-1.png")
    run_rom(SCENE, "--frames", "40", "--press", "30-40:SELECT", "--png", sw1)
    top_same = compare(sw1, sw, 4, 0)[0]
    bot_big = compare(sw1, sw, 4, 1)[1]
    check("3D가 아래 화면으로 가면(엔진 A 바꿈) 고해상도도 아래 화면에", top_same == 0 and bot_big < 49152 * 0.08,
          f"위 다름 {top_same} · 아래 크게 다름 {bot_big}")

    sc = os.path.join(TMP, "scene-switch.png")
    run_rom(SCENE, "--frames", "40", "--scale-at", "10:4", "--scale-at", "20:2", "--scale-at", "30:1", "--png", sc)
    check("도중에 배율을 바꿔도(1 → 4 → 2 → 1) 1배 그림이 그대로", open(sc, "rb").read() == open(s1, "rb").read())
    sc4 = os.path.join(TMP, "scene-switch-4.png")
    run_rom(SCENE, "--frames", "40", "--scale-at", "20:4", "--png", sc4)
    check("도중에 4배로 바꾸면 처음부터 4배와 같은 그림", open(sc4, "rb").read() == open(s4, "rb").read())

    st = os.path.join(TMP, "scene-state.mst")
    a, b = os.path.join(TMP, "scene-state-a.png"), os.path.join(TMP, "scene-state-b.png")
    run_rom(SCENE, "--frames", "61", "--scale", "4", "--state-save", f"30:{st}", "--png-at", f"60:{a}")
    run_rom(SCENE, "--frames", "41", "--scale", "4", "--state-load", f"10:{st}", "--png-at", f"40:{b}")
    check("3D 4배: 상태 불러오기 → 같은 화면", open(a, "rb").read() == open(b, "rb").read())


if __name__ == "__main__":
    sys.exit(main())
