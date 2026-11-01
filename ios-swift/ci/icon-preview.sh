#!/usr/bin/env bash
# App 图标（Icon Composer 的 AppIcon.icon，和「我的 › 图标」里选的备用图标 AppIconLight / AppIconDark）：
# 确认编进了 App，并用 Xcode 自带的 ictool 按各个外观渲染预览。
# 预览图存进诊断产物；另外把 32×32 的缩略图以 notice 注释输出，不登录也能看出图层顺序和颜色对不对。
# 只做检查和预览，不影响打包结果（总是返回 0）。
# 用法：bash ios-swift/ci/icon-preview.sh <输出目录>
set -uo pipefail

OUT="${1:?output dir}"
APP="$OUT/derived-app/Build/Products/Release-iphoneos/Bookkeeping.app"
ICONS="ios-swift/Bookkeeping"
PREVIEW="$OUT/icon-preview"
mkdir -p "$PREVIEW"

ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$APP/Info.plist" 2>/dev/null || true)
if [[ "$ICON_NAME" == "AppIcon" ]]; then
  echo "OK: Info.plist CFBundleIconName = AppIcon"
else
  echo "::warning title=AppIcon::Info.plist 里没有 CFBundleIcons › CFBundlePrimaryIcon › CFBundleIconName = AppIcon（实际是 '${ICON_NAME}'）"
fi
for alt in AppIconLight AppIconDark; do
  if /usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundleAlternateIcons:$alt" "$APP/Info.plist" > /dev/null 2>&1; then
    echo "OK: Info.plist CFBundleAlternateIcons 有 $alt"
  else
    echo "::warning title=AppIcon::Info.plist 里没有 CFBundleIcons › CFBundleAlternateIcons › $alt，「我的 › 图标」换不了桌面图标"
  fi
done
if [[ -e "$APP/icon.json" ]] || compgen -G "$APP/*.icon" > /dev/null; then
  echo "::warning title=AppIcon::.icon 被当成普通文件复制进了 App，没有交给 actool 编译"
fi

# Assets.car 里和图标有关的条目（类型、外观、尺寸）
xcrun assetutil --info "$APP/Assets.car" > "$PREVIEW/assets-info.json" 2>/dev/null
python3 - "$PREVIEW/assets-info.json" <<'PY'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
except Exception as error:
    print(f"::warning title=AppIcon::读不了 assetutil 的输出：{error}")
    sys.exit(0)
rows = []
for e in entries:
    if not isinstance(e, dict) or "AppIcon" not in str(e.get("Name", "")):
        continue
    keys = ("AssetType", "Appearance", "Idiom", "PixelWidth", "PixelHeight", "RenditionName")
    rows.append(" ".join(f"{k}={e[k]}" for k in keys if k in e))
rows = sorted(set(rows))
print("\n".join(rows) or "no AppIcon entries")
message = f"Assets.car 里有 {len(rows)} 种 AppIcon 条目%0A" + "%0A".join(r.replace("%", "%25") for r in rows[:30])
print(f"::notice title=AppIconAssets::{message}" if rows else "::warning title=AppIcon::Assets.car 里没有 AppIcon")
PY

ICTOOL="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ICTOOL" ]]; then
  echo "::warning title=IconPreview::找不到 ictool：$ICTOOL"
  exit 0
fi

# 用法：render <图标名> <外观>，预览图存成 <图标名>-<外观>.png
render() {
  local name="$1-$2" png="$PREVIEW/$1-$2.png"
  "$ICTOOL" "$ICONS/$1.icon" --export-image --output-file "$png" --platform iOS --rendition "$2" \
    --width 1024 --height 1024 --scale 1 > "$PREVIEW/$name.log" 2>&1 \
    || "$ICTOOL" "$ICONS/$1.icon" --export-preview iOS "$2" 1024 1024 1 "$png" >> "$PREVIEW/$name.log" 2>&1
  if [[ ! -f "$png" ]]; then
    help=$("$ICTOOL" --help 2>&1 | head -n 40 | cut -c1-200 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
    echo "::warning title=IconPreview-$name::ictool 没有输出图片：$(tail -n 5 "$PREVIEW/$name.log" | tr '\n' ' ' | cut -c1-400)%0A$help"
    return 0
  fi
  sips -z 32 32 "$png" --out "$PREVIEW/$name-32.png" > /dev/null 2>&1 || return 0
  # 每个像素 4 个十六进制数（RGBA 各 4 位），一行接一行
  python3 - "$PREVIEW/$name-32.png" "$name" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    chunk = data[pos + 8:pos + 8 + length]
    pos += 12 + length
    if kind == b"IHDR":
        width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
    elif kind == b"IDAT":
        idat += chunk
channels = {2: 3, 6: 4, 0: 1, 4: 2}[color]
bpp = channels * depth // 8
raw, stride = zlib.decompress(idat), width * bpp
rows, prev, i = [], bytearray(stride), 0
for _ in range(height):
    kind, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
    i += 1 + stride
    for x in range(stride):
        a = line[x - bpp] if x >= bpp else 0
        b = prev[x]
        c = prev[x - bpp] if x >= bpp else 0
        if kind == 1: line[x] = (line[x] + a) & 255
        elif kind == 2: line[x] = (line[x] + b) & 255
        elif kind == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif kind == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line)
    prev = line
step = depth // 8
out = []
for line in rows:
    for x in range(width):
        px = [line[(x * channels + k) * step] for k in range(channels)]
        if channels <= 2: px = [px[0]] * 3 + px[1:]
        if len(px) == 3: px.append(255)
        out.append("".join("%x" % (v >> 4) for v in px))
print(f"::notice title=IconPreview-{sys.argv[2]}::{width}x{height} rgba4 {''.join(out)}")
PY
}

for rendition in Default Dark TintedLight TintedDark; do render AppIcon "$rendition"; done
# 备用图标不管系统是什么外观都是同一个颜色，看默认外观就够了
for icon in AppIconLight AppIconDark; do render "$icon" Default; done
exit 0
