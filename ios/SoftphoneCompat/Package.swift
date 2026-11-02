// swift-tools-version:5.3
import PackageDescription

// 自研引擎兼容包:product 名与 Acrobits 远程包一致,App 侧 productName 引用零改动。
//
// 双部署形态(方案 A,2026-11-02 定):
// - SDK 仓库本目录:构建缓存(Binaries/ gitignore,../build-ios-sdk.sh 产出)
// - App 仓库 ios/SoftphoneCompat:交付形态(**入库**,build-ios-sdk.sh [6/6]
//   同步)——App 团队 clone 即得双引擎切换能力,无 novoone-sdk 权限依赖。
// 本文件由构建同步覆盖,两处保持一致,勿单侧手改。
let package = Package(
    name: "SoftphoneSwiftPackage-saas",
    products: [
        .library(name: "SoftphoneSwiftPackage-saas", targets: ["Softphone_Swift", "WebRTC"]),
    ],
    targets: [
        .binaryTarget(name: "Softphone_Swift", path: "Binaries/Softphone_Swift.xcframework"),
        .binaryTarget(name: "WebRTC", path: "Binaries/WebRTC.xcframework"),
    ]
)
