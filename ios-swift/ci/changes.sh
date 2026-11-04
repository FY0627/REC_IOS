#!/usr/bin/env bash
# 这次推送改了什么，决定哪些检查要跑：
#   core  BKCore、测试脚本或工作流改了才跑核心业务测试；只改 App 界面时 BKCore 的测试结果不会变
#   icons App 图标或预览脚本改了才渲染图标预览
# 看不出改了什么（手动触发、PR、新分支的第一次推送、之前的提交找不到）时都跑。
# 用法：bash ios-swift/ci/changes.sh <之前的提交，可以为空> <这次的提交>
set -euo pipefail

BEFORE="${1:-}"
AFTER="${2:?commit}"

changed() {
  [[ -z "$BEFORE" || "$BEFORE" =~ ^0+$ ]] && return 0
  git cat-file -e "$BEFORE^{commit}" 2>/dev/null || return 0
  ! git diff --quiet "$BEFORE" "$AFTER" -- "$@"
}

core=false
icons=false
changed ios-swift/Packages ios-swift/ci/test.sh .github/workflows/ios-swift-build.yml && core=true
changed 'ios-swift/Bookkeeping/*.icon*' ios-swift/ci/icon-preview.sh .github/workflows/ios-swift-build.yml && icons=true

{
  echo "core=$core"
  echo "icons=$icons"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
if [[ -n "$BEFORE" && ! "$BEFORE" =~ ^0+$ ]]; then
  git diff --stat "$BEFORE" "$AFTER" 2>/dev/null | tail -n 30 || true
fi
