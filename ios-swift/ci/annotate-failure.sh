#!/usr/bin/env bash
# 失败时把关键错误行转成运行页面上的 error 注释，方便不登录也能看到失败原因。
# 只输出编译 / 测试错误，不包含任何用户数据（CI 里只有合成测试样例）。
# 用法：bash ios-swift/ci/annotate-failure.sh <输出目录>
set -uo pipefail

OUT="${1:?output dir}"
count=0
for log in "$OUT"/logs/*.log; do
  [[ -f "$log" ]] || continue
  name=$(basename "$log")
  matches=$(grep -nE "error:|: error|Fatal error|failed \(|\*\* (BUILD|TEST) FAILED \*\*|Testing failed|XCTAssert|Assertion failed|cannot find|No such module|Undefined symbol" "$log" \
    | grep -vE "warning:|^\s*$" | head -n 60)
  [[ -n "$matches" ]] || continue
  # 每条注释最多 20 行；GitHub 每个步骤最多显示 10 条 error 注释
  while IFS= read -r chunk && [[ $count -lt 9 ]]; do
    [[ -n "$chunk" ]] || continue
    echo "::error title=$name::${chunk}"
    count=$((count + 1))
  done < <(echo "$matches" | cut -c1-400 | awk 'BEGIN{ORS=""} {gsub(/%/,"%25"); print $0 "%0A"} NR%20==0 {print "\n"} END{print "\n"}')
done
if [[ -f "$OUT/ipa-verification.txt" ]]; then
  echo "::error title=IPAReport::$(tail -n 40 "$OUT/ipa-verification.txt" | cut -c1-300 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
fi
if [[ $count -eq 0 ]]; then
  # 没有匹配到错误行时，附上每个日志的最后 15 行
  for log in "$OUT"/logs/*.log; do
    [[ -f "$log" ]] || continue
    echo "::error title=Tail-$(basename "$log")::$(tail -n 15 "$log" | cut -c1-300 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
  done
fi
exit 0
