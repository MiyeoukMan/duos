#!/bin/sh
# App Store에 올릴 빌드: 코어 시험 → 아카이브(Release · 기기용) → App Store Connect 업로드.
#   TEAM=<유료 팀 ID> tools/release.sh                 아카이브 + 업로드(Xcode › 설정 › 계정에 그 팀의 Apple 계정이 로그인돼 있어야 한다)
#   TEAM=<팀 ID> EXPORT_ONLY=1 tools/release.sh        업로드 없이 build/release/export/에 .ipa만(서명 확인용)
#   TEAM=<팀 ID> ARCHIVE_ONLY=1 tools/release.sh       아카이브까지만(무료 팀으로도 되는지 보는 용)
#   BUILD=<빌드 번호>                                   기본은 날짜 · 시각(yymmddHHMM) — 올릴 때마다 앞보다 커야 한다
# 버전(1.0 등)은 Xcode 프로젝트의 MARKETING_VERSION. 결과는 build/release/(저장소에 안 올라감).
set -e
cd "$(dirname "$0")/.."
[ -n "$TEAM" ] || { echo "TEAM=<유료 개발자 팀 ID>가 필요합니다(developer.apple.com › 계정 › Membership details의 Team ID)"; exit 2; }
BUILD=${BUILD:-$(date +%y%m%d%H%M)}
OUT=build/release
ARCHIVE=$OUT/DuoS-$BUILD.xcarchive
mkdir -p "$OUT"
rm -rf "$OUT/export"

echo "── 코어 시험"
make test | tail -1

echo "── 아카이브(빌드 $BUILD)"
xcodebuild -project app/DuoDS.xcodeproj -scheme DuoDS -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD" archive 2>&1 | grep -E "error:|\*\* ARCHIVE" | sort -u
[ -d "$ARCHIVE" ] || { echo "아카이브 실패"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ARCHIVE/Products/Applications/DuoDS.app/Info.plist")
echo "   $ARCHIVE (버전 $VERSION · 빌드 $BUILD)"
[ -z "$ARCHIVE_ONLY" ] || exit 0

DEST=upload
[ -z "$EXPORT_ONLY" ] || DEST=export
sed -e "s/__TEAM__/$TEAM/" -e "s/__DEST__/$DEST/" tools/ExportOptions.plist > "$OUT/ExportOptions.plist"
echo "── 내보내기($DEST)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates 2>&1 | grep -E "error:|EXPORT|[Uu]pload" | sort -u
if [ "$DEST" = upload ]; then
  echo "올렸습니다 — App Store Connect › 앱 › TestFlight에서 처리(10~30분)가 끝나면 보입니다."
else
  ls -la "$OUT/export"
fi
