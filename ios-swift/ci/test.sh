#!/usr/bin/env bash
# 核心业务测试：
#   1. macOS 主机上 `swift test`（BKCore 包，纯 Swift，含 SQLite）
#   2. iOS 模拟器上同一套测试（iOS 的 Foundation / SQLite 行为）
# 用法：bash ios-swift/ci/test.sh <输出目录>
set -euo pipefail
on_error() { echo "::error title=test.sh::test.sh line $1 failed: $2"; }
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# 运行一条测试命令并把输出同时写入日志，返回命令本身的退出码。
# 运行期间暂停 ERR 钩子：钩子里的 echo 会覆盖 PIPESTATUS，导致测试失败被当成成功（第 15–18 次构建就是这样）。
run_logged() {
  local log="$1"; shift
  trap - ERR
  set +e
  "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR
  return "$status"
}

OUT="${1:?output dir}"
PACKAGE_DIR="ios-swift/Packages/BKCore"
mkdir -p "$OUT/logs" "$OUT/results"

# 分层约束：App 不能直接 import 数据库层
if grep -rn --include='*.swift' -E '^\s*(@testable\s+)?import\s+BKDatabase' ios-swift/Bookkeeping; then
  echo "::error::ios-swift/Bookkeeping 直接 import 了 BKDatabase，违反 App → BKBackend → BKDatabase 的依赖方向"
  exit 1
fi

echo "== swift test (macOS host)"
STATUS=0
run_logged "$OUT/logs/swift-test.log" \
  bash -c 'cd "$1" && swift test --parallel --xunit-output "$2"' _ "$PACKAGE_DIR" "$OUT/results/swift-test.xml" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
  echo "::error title=SwiftTest::macOS 主机上的核心业务测试失败（退出码 ${STATUS}）"
  exit $STATUS
fi

echo "== choose an iOS simulator"
DEVICE_ID=$(bash ios-swift/ci/pick-simulator.sh)
echo "simulator: $DEVICE_ID"

echo "== xcodebuild test (iOS Simulator)"
rm -rf "$OUT/results/BKCore-iOS-Simulator.xcresult"
STATUS=0
run_logged "$OUT/logs/simulator-test.log" \
  bash -c 'cd "$1" && xcodebuild test -scheme BKCore-Package -destination "platform=iOS Simulator,id=$2" -derivedDataPath "$3" -resultBundlePath "$4"' \
  _ "$PACKAGE_DIR" "$DEVICE_ID" "$OUT/derived-package" "$OUT/results/BKCore-iOS-Simulator.xcresult" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
  echo "::error title=SimulatorTests::模拟器上的核心业务测试失败（退出码 ${STATUS}）"
  exit $STATUS
fi

# 统计只用于展示，任何一步取不到都不影响结果
trap - ERR
set +e +o pipefail
ls "$OUT/results" > "$OUT/logs/results-listing.txt" 2>&1
HOST_CASES=$(cat "$OUT"/results/swift-test*.xml 2>/dev/null | grep -o '<testcase ' | wc -l | tr -d ' ')
HOST_FAILS=$(cat "$OUT"/results/swift-test*.xml 2>/dev/null | grep -o '<failure' | wc -l | tr -d ' ')
SIM_SUMMARY=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$OUT/logs/simulator-test.log" | tail -n 1 | sed 's/^[[:space:]]*//')
set -e -o pipefail
echo "::notice title=Tests::macOS swift test: ${HOST_CASES} cases, ${HOST_FAILS} failures; iOS Simulator: ${SIM_SUMMARY:-see log}"
# 测试命令成功却没有任何用例，说明测试没有真正运行
if [[ "${HOST_CASES:-0}" -eq 0 ]]; then
  echo "::error title=SwiftTest::macOS 主机上没有运行任何测试用例"
  exit 1
fi
