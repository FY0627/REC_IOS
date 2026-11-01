#!/usr/bin/env bash
# 选 iOS 模拟器：UDID 输出到 stdout，名称与 runtime 输出到 stderr。
# 测试和截图都按目标设备 iPhone 16 Pro（单屏）来选：
#   1. iPhone 16 Pro
#   2. 其他「iPhone <数字> Pro」
#   3. 其他单屏 iPhone
# 双屏机型（iPhone Duo）不使用。同一档里取 runtime 版本最高、机型号最大的。
# 用法：DEVICE_ID=$(bash ios-swift/ci/pick-simulator.sh)
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, sys, re
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not d.get("isAvailable") or not name.startswith("iPhone") or "Duo" in name:
            continue
        if name == "iPhone 16 Pro":
            rank = 3
        elif re.fullmatch(r"iPhone \d+ Pro", name):
            rank = 2
        else:
            rank = 1
        n = re.search(r"\d+", name)
        key = (rank, version, int(n.group()) if n else 0, name)
        if best is None or key > best[0]:
            best = (key, d["udid"], name, runtime)
if best is None:
    sys.exit("no available single-display iPhone simulator")
print(best[1])
print(f"{best[2]} / {best[3]}", file=sys.stderr)
'
