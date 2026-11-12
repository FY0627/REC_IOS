#!/usr/bin/env bash
# 用付费开发者账号签名，归档后直接上传到 App Store Connect（TestFlight），见 ADR 0023。
# 证书和描述文件由 Xcode 用 App Store Connect API 密钥自动创建、下载（云端管理的分发证书），仓库和 Secrets 里都没有证书。
# 用法：bash ios-swift/ci/archive-upload.sh <输出目录> <构建号>
# 需要环境变量：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 文件的全部内容）、APPLE_TEAM_ID
set -euo pipefail
trap 'echo "::error title=archive-upload.sh::archive-upload.sh line $LINENO failed: $BASH_COMMAND"' ERR

OUT="${1:?output dir}"
BUILD_NUMBER="${2:?build number}"
mkdir -p "$OUT/logs" "$OUT/results"

for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 APPLE_TEAM_ID; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error title=Secrets::仓库 Secrets 里没有 $name（Settings › Secrets and variables › Actions）"
    exit 1
  fi
done

KEY_DIR="${RUNNER_TEMP:-$OUT}/asc"
KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
mkdir -p "$KEY_DIR"
printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# 新机器上没有开发证书的私钥，自动签名每次都新建一张「Apple Development」，攒满上限归档就失败。
# 归档前记下已有的，结束时（成功、失败都算）吊销这次新建的（asc-dev-certs.py）
CERTS_BEFORE="$KEY_DIR/dev-certs-before.txt"
python3 ios-swift/ci/asc-dev-certs.py snapshot "$CERTS_BEFORE"
cleanup() {
  python3 ios-swift/ci/asc-dev-certs.py revoke-new "$CERTS_BEFORE" "$KEY_PATH" || true
  rm -rf "$KEY_DIR"
}
trap cleanup EXIT

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)
ARCHIVE="$OUT/REC.xcarchive"

# 构建期间暂停 ERR 钩子：钩子里的 echo 会覆盖 PIPESTATUS（和 build-device.sh 一样）
trap - ERR
set +e
xcodebuild \
  -project ios-swift/Bookkeeping.xcodeproj \
  -scheme Bookkeeping \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/derived-archive" \
  -resultBundlePath "$OUT/results/Archive.xcresult" \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive 2>&1 | tee "$OUT/logs/archive.log"
STATUS=${PIPESTATUS[0]}
set -e
trap 'echo "::error title=archive-upload.sh::archive-upload.sh line $LINENO failed: $BASH_COMMAND"' ERR

if [[ $STATUS -ne 0 ]]; then
  if grep -q "no devices" "$OUT/logs/archive.log"; then
    echo "::error title=Archive::开发者账号里还没有登记设备，自动签名生成不了开发描述文件。到 Certificates, Identifiers & Profiles › Devices 登记自己的 iPhone 后重跑"
  fi
  if grep -q "maximum number of certificates" "$OUT/logs/archive.log"; then
    echo "::error title=Archive::开发证书数量到上限了。到 Certificates, Identifiers & Profiles › Certificates，把以前 CI 建的「Apple Development」证书吊销掉（分发证书别动），再重跑"
  fi
  echo "::error title=Archive::归档失败（退出码 ${STATUS}）"
  exit $STATUS
fi

OPTIONS="$OUT/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

trap - ERR
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT/export" \
  "${AUTH[@]}" 2>&1 | tee "$OUT/logs/export-upload.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "::error title=Upload::签名导出或上传失败（退出码 ${STATUS}），看 export-upload.log"
  exit $STATUS
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
echo "uploaded: $VERSION ($BUILD_NUMBER)"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
