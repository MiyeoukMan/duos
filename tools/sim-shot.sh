#!/bin/bash
# 시뮬레이터 화면을 찍어 build/screens/art/<이름>.png(+ 줄인 -s.jpg)로.  tools/sim-shot.sh 이름
SIM=${SIM:-4A90DB31-EF2F-4643-A241-A54FBACC1D7C}
mkdir -p build/screens/art
xcrun simctl io $SIM screenshot "build/screens/art/$1.png" >/dev/null 2>&1
sips -Z 1100 "build/screens/art/$1.png" --out "build/screens/art/$1-s.jpg" -s format jpeg >/dev/null
