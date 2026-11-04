#!/bin/bash
# iOS compat SDK 构建链:合并静态库 → framework 真机编译 → xcframework → 包壳 Binaries → 同步 App 仓库
# 用法: ./build-ios-sdk.sh [--rebuild-lib] [--with-webrtc-src <path>] [--switch-native] [--no-sync-app] [--app-ios <dir>]
#   --switch-native  构建成功后调 switch_engine.py native 切 App 工程到自研引擎
#   --no-sync-app    跳过 [6/6] App 仓库同步(仅 SDK 仓库本地自验时用)
#   --app-ios <dir>  App 工程 ios 目录(默认 Mac 同步副本路径)
#
# 同步(方案 A,2026-11-02 定,对齐 Android build-and-sync.sh 模式):
# Binaries xcframework + Package.swift + switch_engine.py 同步到 App 仓库
# ios/NovoSDKCompat 并**入库**——App 团队 clone 即得双引擎切换能力,
# 无 novoone-sdk 权限依赖。SDK 仓库侧 Binaries 仅为构建缓存(gitignore)。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$HERE/CompatFW"
VENDOR="$FW_DIR/Vendor"
BINARIES="$HERE/NovoSDKCompat/Binaries"
PJ_LIB_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/novoone-app-sip/demo/libs"
WEBRTC_SRC_DEFAULT="/Users/lzj/Desktop/novosdk/webrtc_checkout/src/out_ios_libs/WebRTC.xcframework"
APP_IOS_DEFAULT="/Users/lzj/Desktop/novosdk/novoone-app/ios"

REBUILD_LIB=0
WEBRTC_SRC="$WEBRTC_SRC_DEFAULT"
WEBRTC_SRC_EXPLICIT=0
SWITCH_NATIVE=0
SYNC_APP=1
APP_IOS="$APP_IOS_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-lib) REBUILD_LIB=1; shift ;;
    --with-webrtc-src) WEBRTC_SRC="$2"; WEBRTC_SRC_EXPLICIT=1; shift 2 ;;
    --switch-native) SWITCH_NATIVE=1; shift ;;
    --no-sync-app) SYNC_APP=0; shift ;;
    --app-ios) APP_IOS="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

echo "==> [1/6] pjsip 合并静态库"
if [[ $REBUILD_LIB -eq 1 || ! -f "$VENDOR/libpjsip-combined.a" ]]; then
  [[ -d "$PJ_LIB_SRC_DEFAULT" ]] || { echo "ERROR: pjsip lib source missing: $PJ_LIB_SRC_DEFAULT"; exit 1; }
  libtool -static -o "$VENDOR/libpjsip-combined.a" "$PJ_LIB_SRC_DEFAULT"/*.a
  echo "    merged $(ls "$PJ_LIB_SRC_DEFAULT" | wc -l | tr -d ' ') .a -> $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1)"
else
  echo "    reuse $(du -h "$VENDOR/libpjsip-combined.a" | cut -f1) (--rebuild-lib 强制重合)"
fi

echo "==> [2/6] WebRTC.xcframework 就位"
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

echo "==> [3/6] 生成工程(pbxproj 自动发现源文件)"
python3 "$FW_DIR/tools/gen_pbxproj.py"

echo "==> [4/6] framework 真机 Release 编译"
BUILD="$FW_DIR/build"
rm -rf "$BUILD"
# 输出落文件再过滤:xcodebuild|grep|head 直连管道在 pipefail 下,过滤命中
# 超 head 上限时 head 先退、SIGPIPE 反杀 xcodebuild——本可成功的构建被误判
XCB_LOG="$BUILD/xcodebuild.log"
mkdir -p "$BUILD"
if ! xcodebuild -project "$FW_DIR/CompatFW.xcodeproj" -scheme NovoSDK_Swift \
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
grep -E 'warning: .*NovoSDK|BUILD (SUCCEEDED|FAILED)' "$XCB_LOG" | head -20 || true
FW="$(find "$BUILD/Build/Products" -name 'NovoSDK_Swift.framework' -path '*Release-iphoneos*' | head -1)"
[[ -d "$FW" ]] || { echo "ERROR: framework not produced"; exit 1; }

echo "==> [5/6] xcframework + Binaries 同步"
mkdir -p "$BINARIES"
rm -rf "$BINARIES/NovoSDK_Swift.xcframework"
xcodebuild -create-xcframework -framework "$FW" -output "$BINARIES/NovoSDK_Swift.xcframework" 2>&1 | tail -1
rm -rf "$BINARIES/WebRTC.xcframework"
cp -Rc "$VENDOR/WebRTC.xcframework" "$BINARIES/"   # APFS clone,同卷瞬时

echo "==> 符号抽查"
# grep -c 零匹配退出码 1 会触发 set -e:恰恰是抽查要抓的异常(合并库过期/
# 符号剥离)会让产物已就位的构建报失败——吞退出码,显式判 0 报错
SYMS=$(nm -g "$BINARIES/NovoSDK_Swift.xcframework/ios-arm64/NovoSDK_Swift.framework/NovoSDK_Swift" 2>/dev/null | grep -c ' [Tt] _pjsua_\| [Tt] _pj_' || true)
if [[ "$SYMS" -eq 0 ]]; then
  echo "ERROR: framework 无 pj* 符号(合并库过期或符号被剥离?)"; exit 1
fi
echo "    framework pj* 符号: $SYMS"
echo "==> DONE: $BINARIES"

if [[ "$SYNC_APP" == 1 ]]; then
  echo "==> [6/6] 同步 App 仓库(物料入库交付)"
  [[ -d "$APP_IOS" ]] || { echo "ERROR: App ios dir not found: $APP_IOS (use --app-ios)"; exit 1; }
  APP_COMPAT="$APP_IOS/NovoSDKCompat"
  mkdir -p "$APP_COMPAT/Binaries"
  rm -rf "$APP_COMPAT/Binaries/NovoSDK_Swift.xcframework" "$APP_COMPAT/Binaries/WebRTC.xcframework"
  cp -Rc "$BINARIES/NovoSDK_Swift.xcframework" "$APP_COMPAT/Binaries/"
  cp -Rc "$BINARIES/WebRTC.xcframework" "$APP_COMPAT/Binaries/"
  cp "$HERE/NovoSDKCompat/Package.swift" "$APP_COMPAT/Package.swift"
  cp "$HERE/switch_engine.py" "$APP_IOS/switch_engine.py"
  rm -f "$APP_COMPAT/Binaries/.gitkeep"   # 产物就位后移除占位
  echo "    synced -> $APP_COMPAT"
  echo "    App 侧入库(由人执行): git add ios/NovoSDKCompat ios/switch_engine.py"
fi

if [[ "$SWITCH_NATIVE" == 1 ]]; then
  echo "==> --switch-native: 切换 App 工程"
  # 方案 A:切换优先用 App 侧脚本副本(SDK_COMPAT 自适应 -> App 本地
  # NovoSDKCompat 引用);未同步过(如 --no-sync-app)回落 SDK 侧副本
  # (引用 SDK 仓库路径,仅 Mac 本机调试形态)
  if [[ -f "$APP_IOS/switch_engine.py" ]]; then
    python3 "$APP_IOS/switch_engine.py" native "$APP_IOS"
  else
    python3 "$HERE/switch_engine.py" native "$APP_IOS"
  fi
fi
