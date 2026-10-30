#!/bin/bash
# novoone-sdk 构建并同步 AAR 到 novoone-app（Android 模块在 android/ 子目录）
# 用法: cd /home/work/novoone-sdk && ./build-and-sync.sh [APP_PATH]

set -e

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-/home/work/novoone-app/android}"

echo "=== 构建 AAR ==="
cd "$SDK_DIR/android"
./gradlew :compat:assembleRelease :sip-core:assembleRelease --console=plain

echo "=== 同步到 App ==="
cp compat/build/outputs/aar/compat-release.aar "$APP_DIR/libs/"
cp sip-core/build/outputs/aar/sip-core-release.aar "$APP_DIR/libs/"
cp libs/libwebrtc-arm64-v8a.aar "$APP_DIR/libs/"

echo "=== 完成 ==="
ls -la "$APP_DIR/libs/"*.aar
echo "App 编译: cd $APP_DIR && ./gradlew :app:assembleStandardRelease"
