#!/bin/bash
# iOS compat SDK 构建链:合并静态库 → framework 真机编译 → xcframework → 包壳 Binaries
# 用法: ./build-ios-sdk.sh [--rebuild-lib] [--with-webrtc-src <path>] [--switch-native]
#   --switch-native  构建成功后调 switch_engine.py native 切 App 工程到自研引擎
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$HERE/CompatFW"
VENDOR="$FW_DIR/Vendor"
BINARIES="$HERE/SoftphoneCompat/Binaries"
PJ_LIB_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/novoone-app/ios/SipCore/pjsip-ios/lib"
WEBRTC_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/novoone-app/ios/SipCore/Frameworks/WebRTC.xcframework"

REBUILD_LIB=0
WEBRTC_SRC="$WEBRTC_SRC_DEFAULT"
SWITCH_NATIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-lib) REBUILD_LIB=1; shift ;;
    --with-webrtc-src) WEBRTC_SRC="$2"; shift 2 ;;
    --switch-native) SWITCH_NATIVE=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -d "$WEBRTC_SRC" ]] || { echo "ERROR: WebRTC.xcframework not found: $WEBRTC_SRC (use --with-webrtc-src)"; exit 1; }

echo "==> [1/5] pjsip 合并静态库"
if [[ $REBUILD_LIB -eq 1 || ! -f "$VENDOR/libpjsip-combined.a" ]]; then
  [[ -d "$PJ_LIB_SRC_DEFAULT" ]] || { echo "ERROR: pjsip lib source missing: $PJ_LIB_SRC_DEFAULT"; exit 1; }
  libtool -static -o "$VENDOR/libpjsip-combined.a" "$PJ_LIB_SRC_DEFAULT"/*.a
  echo "    merged $(ls "$PJ_LIB_SRC_DEFAULT" | wc -l | tr -d ' ') .a -> $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1)"
else
  echo "    reuse $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1) (--rebuild-lib 强制重合)"
fi

echo "==> [2/5] WebRTC.xcframework 就位"
if [[ ! -d "$VENDOR/WebRTC.xcframework" ]]; then
  cp -R "$WEBRTC_SRC" "$VENDOR/"
  echo "    copied from $WEBRTC_SRC"
else
  echo "    present ($(du -sh "$VENDOR/WebRTC.xcframework" | cut -f1))"
fi

echo "==> [3/5] 生成工程(pbxproj 自动发现源文件)"
python3 "$FW_DIR/tools/gen_pbxproj.py"

echo "==> [4/5] framework 真机 Release 编译"
BUILD="$FW_DIR/build"
rm -rf "$BUILD"
xcodebuild -project "$FW_DIR/CompatFW.xcodeproj" -scheme Softphone_Swift \
  -sdk iphoneos -configuration Release \
  -derivedDataPath "$BUILD" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E 'error|warning: .*Softphone|BUILD (SUCCEEDED|FAILED)' | head -20
FW="$(find "$BUILD/Build/Products" -name 'Softphone_Swift.framework' -path '*Release-iphoneos*' | head -1)"
[[ -d "$FW" ]] || { echo "ERROR: framework not produced"; exit 1; }

echo "==> [5/5] xcframework + Binaries 同步"
mkdir -p "$BINARIES"
rm -rf "$BINARIES/Softphone_Swift.xcframework"
xcodebuild -create-xcframework -framework "$FW" -output "$BINARIES/Softphone_Swift.xcframework" 2>&1 | tail -1
rm -rf "$BINARIES/WebRTC.xcframework"
cp -Rc "$VENDOR/WebRTC.xcframework" "$BINARIES/"   # APFS clone,同卷瞬时

echo "==> 符号抽查"
SYMS=$(nm -g "$BINARIES/Softphone_Swift.xcframework/ios-arm64/Softphone_Swift.framework/Softphone_Swift" 2>/dev/null | grep -c ' [Tt] _pjsua_\| [Tt] _pj_')
echo "    framework pj* 符号: $SYMS"
echo "==> DONE: $BINARIES"
if [[ "$SWITCH_NATIVE" == 1 ]]; then
  echo "==> --switch-native: 切换 App 工程"
  python3 "$HERE/switch_engine.py" native
fi
