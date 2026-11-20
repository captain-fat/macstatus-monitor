#!/bin/bash
# 单独公证已经签好名的 .app：
#   ./Scripts/notarize.sh "dist/MacStatus Monitor.app" msm-notary
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?用法: notarize.sh <app 路径> <keychain-profile>}"
PROFILE="${2:?用法: notarize.sh <app 路径> <keychain-profile>}"
TMP=$(mktemp -d)
ditto -c -k --keepParent "$APP" "$TMP/app.zip"
xcrun notarytool submit "$TMP/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -rf "$TMP"
echo "已公证并装订：$APP"
