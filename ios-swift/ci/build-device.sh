#!/usr/bin/env bash
# 构建 Release / iphoneos / arm64 真机 App，不签名（签名交给用户本地的 iLoader）。
# 这里不走 archive + exportArchive：未签名的 archive 不能用常规导出流程生成 IPA，
# 所以直接构建真机 .app，再由 package-ipa.sh 按 Payload/<App>.app 结构打包。
# 用法：bash ios-swift/ci/build-device.sh <输出目录> <构建号>
set -euo pipefail
trap 'echo "::error title=build-device.sh::build-device.sh line $LINENO failed: $BASH_COMMAND"' ERR

OUT="${1:?output dir}"
BUILD_NUMBER="${2:-1}"
mkdir -p "$OUT/logs" "$OUT/results"
rm -rf "$OUT/results/Build-Release-iphoneos.xcresult"

# 构建期间暂停 ERR 钩子：钩子里的 echo 会覆盖 PIPESTATUS，构建失败会被当成成功（和 test.sh 一样）
trap - ERR
set +e
xcodebuild \
  -project ios-swift/Bookkeeping.xcodeproj \
  -scheme Bookkeeping \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/derived-app" \
  -resultBundlePath "$OUT/results/Build-Release-iphoneos.xcresult" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  clean build 2>&1 | tee "$OUT/logs/build-device.log"
STATUS=${PIPESTATUS[0]}
set -e
trap 'echo "::error title=build-device.sh::build-device.sh line $LINENO failed: $BASH_COMMAND"' ERR

if [[ $STATUS -ne 0 ]]; then
  echo "::error title=DeviceBuild::Release iphoneos 构建失败（退出码 ${STATUS}）"
  exit $STATUS
fi

APP="$OUT/derived-app/Build/Products/Release-iphoneos/Bookkeeping.app"
if [[ ! -d "$APP" ]]; then
  echo "::error::构建成功但没有找到 $APP"
  exit 1
fi
echo "built: $APP"
