#!/usr/bin/env bash
# 选择 Xcode 并记录真实工具链版本。不写死版本号：以 runner 实际安装的为准。
# 用法：bash ios-swift/ci/toolchain.sh <输出目录>
set -euo pipefail
trap 'echo "::error title=toolchain.sh::toolchain.sh line $LINENO failed: $BASH_COMMAND"' ERR

OUT="${1:?output dir}"
mkdir -p "$OUT/logs"

# 优先使用环境变量 XCODE_APP（例如 /Applications/Xcode_27.0.app）；否则用 runner 的默认 Xcode。
if [[ -n "${XCODE_APP:-}" ]]; then
  if [[ ! -d "$XCODE_APP" ]]; then
    echo "::error::XCODE_APP=$XCODE_APP 不存在。已安装的 Xcode：$(ls -d /Applications/Xcode*.app | tr '\n' ' ')"
    exit 1
  fi
  sudo xcode-select -s "$XCODE_APP/Contents/Developer"
fi

INFO="$OUT/toolchain.txt"
{
  echo "runner_os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
  echo "xcode_path: $(xcode-select -p)"
  echo "xcodebuild: $(xcodebuild -version | tr '\n' ' ')"
  echo "swift: $(swift --version 2>&1 | head -n 1)"
  echo "iphoneos_sdk: $(xcrun --sdk iphoneos --show-sdk-version) ($(xcrun --sdk iphoneos --show-sdk-build-version)) $(xcrun --sdk iphoneos --show-sdk-path)"
  echo "iphonesimulator_sdk: $(xcrun --sdk iphonesimulator --show-sdk-version)"
  echo "installed_xcodes: $(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
} | tee "$INFO"

echo "--- available SDKs" >> "$OUT/logs/toolchain-details.log"
xcodebuild -showsdks >> "$OUT/logs/toolchain-details.log" 2>&1 || true
echo "--- simulator runtimes" >> "$OUT/logs/toolchain-details.log"
xcrun simctl list runtimes >> "$OUT/logs/toolchain-details.log" 2>&1 || true

# 部署目标不得高于用户设备的 iOS 27.0.1，且 SDK 必须支持该部署目标
DEPLOYMENT=$(grep -m1 -o 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*' ios-swift/Bookkeeping.xcodeproj/project.pbxproj | awk '{print $3}')
SDK=$(xcrun --sdk iphoneos --show-sdk-version)
echo "deployment_target: $DEPLOYMENT" | tee -a "$INFO"
python3 - "$DEPLOYMENT" "$SDK" <<'PY'
import sys
def v(s): return tuple(int(x) for x in s.split('.'))
dep, sdk = sys.argv[1], sys.argv[2]
assert v(dep) <= v("27.0.1"), f"deployment target {dep} is higher than iOS 27.0.1"
assert v(dep) <= v(sdk), f"deployment target {dep} is higher than SDK {sdk}"
print(f"deployment target {dep} <= iOS 27.0.1 and <= SDK {sdk}: OK")
PY

# 在运行页面上以 notice 形式公开工具链信息
echo "::notice title=Toolchain::$(paste -sd ';' "$INFO")"
