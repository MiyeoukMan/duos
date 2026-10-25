#!/bin/sh
# 시뮬레이터(iPhone Duo)에 빌드 · 설치하고, 시험 ROM들을 넣고 켠다. 나머지 인자는 앱 실행 인자로 넘긴다.
#   tools/sim-run.sh -DuoHinge closed        (접은 상태로 시작 — 두 손가락 톡으로 접기 ↔ 펴기)
set -e
cd "$(dirname "$0")/.."
SIM=${SIM:-$(xcrun simctl list devices booted | grep "iPhone Duo" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}
[ -n "$SIM" ] || { echo "켜진 iPhone Duo 시뮬레이터가 없습니다"; exit 1; }
xcodebuild -project app/DuoDS.xcodeproj -target DuoDS -configuration Release -sdk iphonesimulator \
  SYMROOT="$PWD/build/xcode" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|\*\* BUILD" | sort -u
xcrun simctl install "$SIM" build/xcode/Release-iphonesimulator/DuoDS.app
DATA=$(xcrun simctl get_app_container "$SIM" com.singularity2131.duods data)
mkdir -p "$DATA/Documents/ROMs"
[ -f build/test.nds ] || python3 tools/mkrom.py build/test.nds
[ -d build/showcase ] || python3 tools/mkrom.py --showcase build/showcase
cp build/test.nds build/showcase/*.nds "$DATA/Documents/ROMs/"
xcrun simctl launch --terminate-running-process "$SIM" com.singularity2131.duods "$@"
