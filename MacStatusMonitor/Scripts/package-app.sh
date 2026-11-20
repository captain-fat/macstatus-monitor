#!/bin/bash
# 组装、签名并打包 .app。
#
#   本地自用（ad-hoc）：      ./Scripts/package-app.sh
#   Developer ID 签名：       CODESIGN_IDENTITY="Developer ID Application: Xxx (TEAMID)" ./Scripts/package-app.sh
#   Developer ID + 公证：     CODESIGN_IDENTITY="..." NOTARY_PROFILE="msm-notary" ./Scripts/package-app.sh
#
# 公证前需要先保存一次凭据：
#   xcrun notarytool store-credentials "msm-notary" --apple-id <id> --team-id <team> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacStatus Monitor"
EXECUTABLE="MacStatusMonitor"
APP="dist/${APP_NAME}.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="dist/MacStatusMonitor-${VERSION}.zip"
DMG="dist/MacStatusMonitor-${VERSION}.dmg"

./Scripts/build.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${EXECUTABLE}" "$APP/Contents/MacOS/${EXECUTABLE}"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -3

# 可选：公证并装订
if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  echo "提交公证（profile: ${NOTARY_PROFILE}）..."
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

# DMG 需要完整的磁盘映像权限；在受限环境（CI/沙盒）里失败不阻塞交付
if hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
  echo "已生成："
  echo "  $APP"
  echo "  $ZIP"
  echo "  $DMG"
else
  echo "已生成："
  echo "  $APP"
  echo "  $ZIP"
  echo "（DMG 创建失败：当前环境不允许挂载磁盘映像；在普通终端重跑本脚本即可生成。）"
fi
echo "签名身份: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
  echo "提示：ad-hoc 签名只能本机运行；分发请用 Developer ID 重新执行本脚本。"
fi
