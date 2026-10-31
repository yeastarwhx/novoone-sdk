#!/bin/bash
# iOS compat SDK 构建链:合并静态库 → framework 真机编译 → xcframework → 包壳 Binaries
# 用法: ./build-ios-sdk.sh [--rebuild-lib] [--with-webrtc-src <path>] [--switch-native]
#   --switch-native  构建成功后调 switch_engine.py native 切 App 工程到自研引擎
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$HERE/CompatFW"
VENDOR="$FW_DIR/Vendor"
BINARIES="$HERE/SoftphoneCompat/Binaries"
PJ_LIB_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/novoone-app-sip/demo/libs"
WEBRTC_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/webrtc_checkout/src/out_ios_libs/WebRTC.xcframework"

REBUILD_LIB=0
WEBRTC_SRC="$WEBRTC_SRC_DEFAULT"
WEBRTC_SRC_EXPLICIT=0
SWITCH_NATIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-lib) REBUILD_LIB=1; shift ;;
    --with-webrtc-src) WEBRTC_SRC="$2"; WEBRTC_SRC_EXPLICIT=1; shift 2 ;;
    --switch-native) SWITCH_NATIVE=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

echo "==> [1/5] pjsip 合并静态库"
if [[ $REBUILD_LIB -eq 1 || ! -f "$VENDOR/libpjsip-combined.a" ]]; then
  [[ -d "$PJ_LIB_SRC_DEFAULT" ]] || { echo "ERROR: pjsip lib source missing: $PJ_LIB_SRC_DEFAULT"; exit 1; }
  libtool -static -o "$VENDOR/libpjsip-combined.a" "$PJ_LIB_SRC_DEFAULT"/*.a
  echo "    merged $(ls "$PJ_LIB_SRC_DEFAULT" | wc -l | tr -d ' ') .a -> $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1)"
else
  echo "    reuse $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1) (--rebuild-lib 强制重合)"
fi

echo "==> [2/5] WebRTC.xcframework 就位"
if [[ -d "$VENDOR/WebRTC.xcframework" ]]; then
  echo "    present ($(du -sh "$VENDOR/WebRTC.xcframework" | cut -f1))"
  if [[ $WEBRTC_SRC_EXPLICIT -eq 1 ]]; then
    echo "    WARNING: --with-webrtc-src ignored (Vendor already present) —"
    echo "    rm -rf '$VENDOR/WebRTC.xcframework' first to force refresh from: $WEBRTC_SRC"
  fi
elif [[ -d "$WEBRTC_SRC" ]]; then
  cp -R "$WEBRTC_SRC" "$VENDOR/"
  echo "    copied from $WEBRTC_SRC"
else
  echo "ERROR: WebRTC.xcframework not found: $WEBRTC_SRC (use --with-webrtc-src)"; exit 1
fi

echo "==> [3/5] 生成工程(pbxproj 自动发现源文件)"
python3 "$FW_DIR/tools/gen_pbxproj.py"

echo "==> [4/5] framework 真机 Release 编译"
BUILD="$FW_DIR/build"
rm -rf "$BUILD"
# 输出落文件再过滤:xcodebuild|grep|head 直连管道在 pipefail 下,过滤命中
# 超 head 上限时 head 先退、SIGPIPE 反杀 xcodebuild——本可成功的构建被误判
XCB_LOG="$BUILD/xcodebuild.log"
mkdir -p "$BUILD"
if ! xcodebuild -project "$FW_DIR/CompatFW.xcodeproj" -scheme Softphone_Swift \
  -sdk iphoneos -configuration Release \
  -derivedDataPath "$BUILD" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
  build > "$XCB_LOG" 2>&1; then
  # || true:grep 零匹配(信号杀死等无字面 error 的失败)退出 1 会先于
  # 下行 echo 触发 set -e,恰丢掉完整日志指引
  grep -E 'error' "$XCB_LOG" | head -20 || true
  echo "ERROR: CompatFW build failed (full log: $XCB_LOG)"
  exit 1
fi
grep -E 'warning: .*Softphone|BUILD (SUCCEEDED|FAILED)' "$XCB_LOG" | head -20 || true
FW="$(find "$BUILD/Build/Products" -name 'Softphone_Swift.framework' -path '*Release-iphoneos*' | head -1)"
[[ -d "$FW" ]] || { echo "ERROR: framework not produced"; exit 1; }

echo "==> [5/5] xcframework + Binaries 同步"
mkdir -p "$BINARIES"
rm -rf "$BINARIES/Softphone_Swift.xcframework"
xcodebuild -create-xcframework -framework "$FW" -output "$BINARIES/Softphone_Swift.xcframework" 2>&1 | tail -1
rm -rf "$BINARIES/WebRTC.xcframework"
cp -Rc "$VENDOR/WebRTC.xcframework" "$BINARIES/"   # APFS clone,同卷瞬时

echo "==> 符号抽查"
# grep -c 零匹配退出码 1 会触发 set -e:恰恰是抽查要抓的异常(合并库过期/
# 符号剥离)会让产物已就位的构建报失败——吞退出码,显式判 0 报错
SYMS=$(nm -g "$BINARIES/Softphone_Swift.xcframework/ios-arm64/Softphone_Swift.framework/Softphone_Swift" 2>/dev/null | grep -c ' [Tt] _pjsua_\| [Tt] _pj_' || true)
if [[ "$SYMS" -eq 0 ]]; then
  echo "ERROR: framework 无 pj* 符号(合并库过期或符号被剥离?)"; exit 1
fi
echo "    framework pj* 符号: $SYMS"
echo "==> DONE: $BINARIES"
if [[ "$SWITCH_NATIVE" == 1 ]]; then
  echo "==> --switch-native: 切换 App 工程"
  python3 "$HERE/switch_engine.py" native
fi
