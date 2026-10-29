// swift-tools-version:5.3
import PackageDescription

// 自研引擎兼容包:product 名与 Acrobits 远程包一致,App 侧 productName 引用零改动。
// Binaries/ 不入 git,由 ../build-ios-sdk.sh 产出。
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
