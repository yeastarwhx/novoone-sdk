// swift-tools-version:5.3
import PackageDescription

// NovoSDK 自研引擎包:
// 包名 NovoSDKSwiftPackage/module NovoSDK_Swift 均为 NovoSDK 自有命名,
// 不再与 Acrobits 远程包同名顶替——双引擎切换改由 switch_engine.py 的
// 双名字切换承担(pbxproj 的包引用与 productName 同步变换)。
//
// 双部署形态:
// - SDK 仓库本目录:构建缓存(Binaries/ gitignore,../build-ios-sdk.sh 产出)
// - App 仓库 ios/NovoSDKCompat:交付形态(**入库**,build-ios-sdk.sh
//   同步)——App 团队 clone 即得双引擎切换能力,无 SDK 源码仓权限依赖。
// 本文件由构建同步覆盖,两处保持一致,勿单侧手改。
let package = Package(
    name: "NovoSDKSwiftPackage",
    products: [
        .library(name: "NovoSDKSwiftPackage", targets: ["NovoSDK_Swift", "WebRTC"]),
    ],
    targets: [
        .binaryTarget(name: "NovoSDK_Swift", path: "Binaries/NovoSDK_Swift.xcframework"),
        .binaryTarget(name: "WebRTC", path: "Binaries/WebRTC.xcframework"),
    ]
)
