#!/bin/bash
# Android SDK 构建并同步 AAR 到 novoone-app（与 ios/build-ios-sdk.sh 对称）
# 用法: ./build-and-sync.sh [APP_ANDROID_DIR]
#   APP_ANDROID_DIR 也可经环境变量提供；缺省 ~/novoone-app/android，
#   不存在时提示（团队各自 clone 路径不同，不做个人路径假设）。

set -e

SDK_ANDROID_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-${APP_ANDROID_DIR:-$HOME/novoone-app/android}}"

if [ ! -d "$APP_DIR" ]; then
    echo "错误: App 工程 Android 目录不存在: $APP_DIR" >&2
    echo "用法: ./build-and-sync.sh [APP_ANDROID_DIR]  (或 export APP_ANDROID_DIR=...)" >&2
    exit 1
fi

echo "=== 构建 AAR ==="
cd "$SDK_ANDROID_DIR"
./gradlew :novosdk:assembleRelease :sip-core:assembleRelease --console=plain

echo "=== 同步到 App ==="
cp novosdk/build/outputs/aar/novosdk-release.aar "$APP_DIR/libs/"
cp sip-core/build/outputs/aar/sip-core-release.aar "$APP_DIR/libs/"
cp libs/libwebrtc-arm64-v8a.aar "$APP_DIR/libs/"

echo "=== 完成 ==="
ls -la "$APP_DIR/libs/"*.aar
echo "App 编译: cd $APP_DIR && ./gradlew :app:assembleStandardRelease"
