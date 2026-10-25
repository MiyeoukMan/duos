#!/bin/sh
# 기기용으로 빌드(서명)하고, 기기가 연결될 때까지 기다렸다가 깔고 켠다.
#   tools/device-install.sh            (기기는 tools/device.local의 DEVICE)
#   DEVICE=<UDID> WAIT=0 NOLAUNCH=1 tools/device-install.sh   (NOLAUNCH: 깔기만 하고 켜지 않음, SKIPBUILD: 빌드 건너뜀, TEAM: 서명 팀)
# 기기 UDID는 저장소에 넣지 않는다 — tools/device.local(무시 목록)에 `DEVICE=<UDID>` 한 줄(`xcrun devicectl list devices`로 확인)
set -e
cd "$(dirname "$0")/.."
[ -n "$DEVICE" ] || { [ -f tools/device.local ] && . tools/device.local; }
[ -n "$DEVICE" ] || { echo "기기 UDID가 없습니다: DEVICE=<UDID>로 실행하거나 tools/device.local에 적으세요"; exit 2; }
TEAM=${TEAM:-3C3P339A53}
WAIT=${WAIT:-7200}
[ -n "$SKIPBUILD" ] || xcodebuild -project app/DuoDS.xcodeproj -target DuoDS -configuration Release -sdk iphoneos SYMROOT="$PWD/build/xcode" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$TEAM build 2>&1 \
  | grep -E "error:|\*\* BUILD" | sort -u
APP=build/xcode/Release-iphoneos/DuoDS.app
start=$(date +%s)
LOG=build/install-$DEVICE.log
rm -f "$LOG"   # 지난 설치 기록을 이번 결과로 착각하지 않게(2026-10-25에 그랬다)
echo "기기($DEVICE)를 기다리는 중…"
until xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -qv unavailable && \
      xcrun devicectl device install app --device "$DEVICE" "$APP" >"$LOG" 2>&1; do
  if [ $(( $(date +%s) - start )) -ge "$WAIT" ]; then
    echo "설치 실패: 기기를 $WAIT초 기다렸지만 연결되지 않았습니다(또는 설치 오류)."
    [ -f "$LOG" ] && tail -3 "$LOG"
    exit 1
  fi
  sleep 10
done
echo "설치 완료: $(date '+%H:%M:%S')"
grep -E "bundleID|installationURL" "$LOG"
[ -n "$NOLAUNCH" ] || xcrun devicectl device process launch --device "$DEVICE" com.singularity2131.duods 2>&1 | tail -2
