#!/usr/bin/env bash
# 把真机 .app 打包成可由 iLoader 重新签名的 IPA，并校验完整性。
# 用法：bash ios-swift/ci/package-ipa.sh <输出目录>
set -euo pipefail
# 任何未被 fail() 捕获的命令失败也要在运行页面上留下行号
trap 'echo "::error title=IPAVerification::package-ipa.sh 第 $LINENO 行命令失败：$BASH_COMMAND"' ERR

OUT="${1:?output dir}"
APP="$OUT/derived-app/Build/Products/Release-iphoneos/Bookkeeping.app"
EXPECTED_BUNDLE_ID="com.example.bookkeepingApp.swift"
REPORT="$OUT/ipa-verification.txt"
mkdir -p "$OUT/ipa" "$OUT/stage"
: > "$REPORT"

fail() { echo "::error title=IPAVerification::$1"; echo "FAIL: $1" >> "$REPORT"; exit 1; }
ok() { echo "OK: $1" | tee -a "$REPORT"; }

[[ -d "$APP" ]] || fail "找不到 $APP"
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || fail "缺少 Info.plist"

read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
EXECUTABLE=$(read_key CFBundleExecutable)
BUNDLE_ID=$(read_key CFBundleIdentifier)
VERSION=$(read_key CFBundleShortVersionString)
BUILD=$(read_key CFBundleVersion)
MIN_OS=$(read_key MinimumOSVersion)
PLATFORM=$(read_key CFBundleSupportedPlatforms:0)

[[ -n "$EXECUTABLE" && -f "$APP/$EXECUTABLE" ]] || fail "可执行文件缺失：$EXECUTABLE"
ok "可执行文件 $EXECUTABLE"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "Bundle ID 是 ${BUNDLE_ID}，期望 $EXPECTED_BUNDLE_ID"
ok "Bundle ID $BUNDLE_ID"
[[ "$PLATFORM" == "iPhoneOS" ]] || fail "CFBundleSupportedPlatforms 是 ${PLATFORM}，不是真机 iPhoneOS"
ok "平台 $PLATFORM"
python3 - "$MIN_OS" <<'PY' || fail "MinimumOSVersion 高于 27.0.1"
import sys
v = tuple(int(x) for x in sys.argv[1].split('.'))
sys.exit(0 if v <= (27, 0, 1) else 1)
PY
ok "MinimumOSVersion ${MIN_OS}（不高于 27.0.1）"

ARCHS=$(lipo -archs "$APP/$EXECUTABLE")
[[ "$ARCHS" == "arm64" ]] || fail "架构是 '$ARCHS'，期望仅 arm64"
ok "架构 $ARCHS"

# LC_BUILD_VERSION platform 2 = iOS 真机，7 = iOS 模拟器
# awk 读完全部输入（不提前 exit），避免 pipefail 下 otool 收到 SIGPIPE
otool -l "$APP/$EXECUTABLE" > "$OUT/load-commands.txt"
BUILD_PLATFORM=$(awk '/LC_BUILD_VERSION/{f=1} f&&/platform/&&!done{print $2; done=1}' "$OUT/load-commands.txt")
MINOS=$(awk '/LC_BUILD_VERSION/{f=1} f&&/minos/&&!done{print $2; done=1}' "$OUT/load-commands.txt")
echo "LC_BUILD_VERSION platform=$BUILD_PLATFORM minos=$MINOS" >> "$REPORT"
PLATFORM_UPPER=$(echo "$BUILD_PLATFORM" | tr '[:lower:]' '[:upper:]')
[[ "$PLATFORM_UPPER" == "2" || "$PLATFORM_UPPER" == "IOS" || "$PLATFORM_UPPER" == "PLATFORM_IOS" ]] || fail "Mach-O 平台是 ${BUILD_PLATFORM}，不是 iOS 真机（模拟器产物不能打包）"
ok "Mach-O 平台 iOS 真机（${BUILD_PLATFORM}）"

# 依赖：系统库或包内 Frameworks
while read -r dep; do
  case "$dep" in
    /System/*|/usr/lib/*) ;;
    @rpath/*)
      name="${dep#@rpath/}"
      [[ -e "$APP/Frameworks/$name" ]] || fail "依赖 $dep 没有打包进 Frameworks/"
      ;;
    *) fail "未知依赖路径 $dep" ;;
  esac
done < <(otool -L "$APP/$EXECUTABLE" | tail -n +2 | awk '{print $1}')
ok "动态依赖仅为系统库$( [[ -d "$APP/Frameworks" ]] && echo '与内置 Frameworks' )"

[[ -f "$APP/Assets.car" ]] || fail "缺少 Assets.car（资源目录未编译）"
ok "资源 Assets.car"

INTENTS="$APP/Metadata.appintents"
[[ -d "$INTENTS" ]] || fail "缺少 Metadata.appintents：App Intents 元数据未生成，快捷指令将找不到动作"
ACTIONS=$(find "$INTENTS" -name 'extract.actionsdata' -print -quit)
find "$INTENTS" -type f >> "$REPORT"
[[ -n "$ACTIONS" ]] || fail "缺少 extract.actionsdata"
grep -q "RecordBankMessageIntent" "$ACTIONS" || fail "App Intents 元数据里没有 RecordBankMessageIntent"
grep -q "AccountEntity" "$ACTIONS" || fail "App Intents 元数据里没有 AccountEntity"
ok "App Intents 元数据包含 RecordBankMessageIntent / AccountEntity"
python3 - "$ACTIONS" >> "$REPORT" <<'PY' || true
import json, sys
data = json.load(open(sys.argv[1]))
for action_id, action in (data.get("actions") or {}).items():
    print(f"action: {action_id} modes={action.get('supportedModes') or action.get('openAppWhenRun')} params={[p.get('name') for p in action.get('parameters', [])]}")
PY

[[ ! -d "$APP/_CodeSignature" ]] && ok "未签名（CI 不使用任何证书，由 iLoader 签名）" || ok "存在 _CodeSignature（将被 iLoader 替换）"
[[ ! -f "$APP/embedded.mobileprovision" ]] || fail "不应包含描述文件"

if [[ -n "${GITHUB_SHA:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :BKBuildCommit string $GITHUB_SHA" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :BKBuildCommit $GITHUB_SHA" "$PLIST"
fi

SHORT_SHA="${GITHUB_SHA:-local}"
SHORT_SHA="${SHORT_SHA:0:8}"
NAME="Bookkeeping-${VERSION}-b${BUILD}-${SHORT_SHA}"
rm -rf "$OUT/stage/Payload"
mkdir -p "$OUT/stage/Payload"
ditto "$APP" "$OUT/stage/Payload/Bookkeeping.app"
(cd "$OUT/stage" && zip -qry "$OUT/ipa/$NAME.ipa" Payload)

unzip -l "$OUT/ipa/$NAME.ipa" > "$OUT/ipa-contents.txt"
grep -q " Payload/Bookkeeping.app/$EXECUTABLE$" "$OUT/ipa-contents.txt" || fail "IPA 结构不对：缺少 Payload/Bookkeeping.app/$EXECUTABLE"
grep -q " Payload/Bookkeeping.app/Info.plist$" "$OUT/ipa-contents.txt" || fail "IPA 结构不对：缺少 Info.plist"
grep -q " Payload/Bookkeeping.app/Metadata.appintents/" "$OUT/ipa-contents.txt" || fail "IPA 里缺少 App Intents 元数据"
ok "IPA 结构 Payload/Bookkeeping.app"

SHA256=$(shasum -a 256 "$OUT/ipa/$NAME.ipa" | awk '{print $1}')
echo "$SHA256  $NAME.ipa" > "$OUT/ipa/$NAME.ipa.sha256"
SIZE=$(stat -f%z "$OUT/ipa/$NAME.ipa")

{
  echo "name: $NAME.ipa"
  echo "sha256: $SHA256"
  echo "size_bytes: $SIZE"
  echo "bundle_id: $BUNDLE_ID"
  echo "version: $VERSION"
  echo "build: $BUILD"
  echo "minimum_os: $MIN_OS"
  echo "commit: ${GITHUB_SHA:-local}"
  echo "ref: ${GITHUB_REF:-local}"
  echo "run: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  cat "$OUT/toolchain.txt" 2>/dev/null || true
} > "$OUT/ipa/build-info.txt"
cp "$REPORT" "$OUT/ipa/"
cat "$OUT/ipa/build-info.txt"

echo "ipa_name=$NAME" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "sha256=$SHA256" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::notice title=IPA::$NAME.ipa sha256=$SHA256 size=$SIZE bundle=$BUNDLE_ID version=$VERSION($BUILD) min=$MIN_OS commit=${GITHUB_SHA:-local}"
