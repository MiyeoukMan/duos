#!/usr/bin/env python3
"""앱 아이콘(1024 × 1024 PNG)을 그린다 — 반쯤 펼친 두 화면 기기. 외부 패키지 없이(zlib만)."""
import math
import struct
import sys
import zlib

N = 1024


def sd_round_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - hw + r
    qy = abs(py - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def cover(d):
    return min(max(0.5 - d, 0.0), 1.0)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def shade(x, y):
    # 바탕: 위에서 아래로 짙어지는 남색
    t = y / N
    col = mix((34, 44, 78), (12, 15, 28), t)
    # 기기 몸: 위 판 · 아래 판(가운데 접힌 선)
    body_top = sd_round_rect(x, y, 512, 300, 330, 210, 70)
    body_bot = sd_round_rect(x, y, 512, 736, 330, 210, 70)
    body = min(body_top, body_bot)
    col = mix(col, (44, 48, 60), cover(body))
    col = mix(col, (58, 63, 78), cover(body + 6) * (0.5 if y < 512 else 0.35))
    # 접힌 선
    if abs(y - 518) < 10 and abs(x - 512) < 300:
        col = mix(col, (24, 26, 34), 0.9)
    # 위 화면
    s1 = sd_round_rect(x, y, 512, 300, 250, 172, 18)
    g = (y - 128) / 344
    col = mix(col, mix((120, 190, 255), (70, 120, 240), g), cover(s1))
    # 아래 화면(작게) + 십자키 · 버튼
    s2 = sd_round_rect(x, y, 512, 730, 160, 122, 14)
    col = mix(col, mix((150, 225, 255), (90, 170, 245), (y - 608) / 244), cover(s2))
    dp = min(sd_round_rect(x, y, 260, 730, 46, 14, 5), sd_round_rect(x, y, 260, 730, 14, 46, 5))
    col = mix(col, (200, 205, 220), cover(dp))
    for bx, by in ((764, 700), (764, 760), (734, 730), (794, 730)):
        col = mix(col, (200, 205, 220), cover(math.hypot(x - bx, y - by) - 15))
    return col


def main(out):
    rows = []
    for y in range(N):
        row = bytearray([0])
        for x in range(N):
            r, g, b = shade(x + 0.5, y + 0.5)
            row += bytes((int(r), int(g), int(b)))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)


if __name__ == "__main__":
    main(sys.argv[1])
