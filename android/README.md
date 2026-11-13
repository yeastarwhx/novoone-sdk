# Android 双引擎 SDK（novoone-app-sdk/android）

NovoSDK Android 侧：**NovoSDK 门面**（`novosdk/`，包名 `com.novosdk.*`，
接口形状对齐 Acrobits Softphone，App 迁移零改动）+ **自研 SipWebrtcEngine**
（`sip-core/`，pjsip 2.17 WebRTC 集成模式信令 + WebRTC aar 媒体）。
与 [ios/](../ios/) 对称，宿主 App 双引擎切换时两个引擎共用同一套
`com.novosdk.*` 调用面。

## 目录结构

```
├── novosdk/                  # 门面层（:compat 模块，包名 com.novosdk）
│   ├── .../com/novosdk/      # Instance/SDK/Preferences/data/event/ali/support
│   │   └── telecom/          # ConnectionService 基类 + compat 分版
│   │       └── compat/       # ConnectionImplApi23/26/34/35 + 工厂（单一 pickLevel）
│   └── .../com/yeastar/sipcore/  # SdkBridge 桥 + PushTokenReporter + 前台服务
├── sip-core/                 # 引擎层（:sip-core 模块）
│   ├── src/main/cpp/         # pjsip_jni.c（JNI 桥）+ ys_pjsua_app.{cpp,h}（信令封装）
│   │   └── CMakeLists.txt    # 17 个 pjsip .a + OpenSSL 静态链入 → libpjsip_jni.so
│   ├── src/main/java/        # SipWebrtcEngine/CallSession/Registry/NetworkMonitor/
│   │                         # AudioRouteHelper/RingtoneHelper/JniBridge
│   └── pjsip-android/        # pjsip arm64 交付物（include 头 + lib/*.a + openssl）
├── libs/
│   ├── libwebrtc-arm64-v8a.aar   # WebRTC aar（org.webrtc，jni_zero 产物）
│   └── webrtc/                # aar 包装模块（字节码版本降级补丁）
├── build-and-sync.sh         # 构建链：AAR 构建 → 同步 App 仓 libs/
└── README.md
```

## 构建

```bash
./build-and-sync.sh [APP_ANDROID_DIR]   # 缺省 $APP_ANDROID_DIR 或 ~/novoone-app/android
```

产出三个 AAR 同步到 App 仓 `android/libs/`：`novosdk-release.aar`（门面）、
`sip-core-release.aar`（引擎 + libpjsip_jni.so）、`libwebrtc-arm64-v8a.aar`（媒体）。

依赖（已随仓入库，clone 即可构建）：

| 依赖 | 来源 | 更新方式 |
|---|---|---|
| pjsip 静态库 ×17 + 头文件 | `sip-core/pjsip-android/`（`lib/`+`include/`） | pjsip 仓根 `make -f Makefile.copy copy-all DEST_DIR=<本目录>/sip-core/pjsip-android ANDROID_ABI=aarch64-unknown-linux-android`（CMake 缺失时报错自述同款命令） |
| OpenSSL（TLS 信令） | `sip-core/pjsip-android/openssl/`（libssl/libcrypto + 头） | 随 pjsip 仓 `third_party/openssl-android/` 重制脚本更新 |
| WebRTC aar | `libs/libwebrtc-arm64-v8a.aar` 单一副本 | 直接覆盖；`:libs:webrtc` 模块构建期自动降级 classes.jar 字节码版本（JDK 25 → 61，见 `libs/webrtc/build.gradle`） |

工具链要求：JDK 17、Android SDK（compileSdk 36）、NDK 27.1.12297006、
CMake 3.22.1。仅 `arm64-v8a`。

## 引擎切换（App 工程）

App 仓（novoone-app）经 gradle 参数切换：

```bash
./gradlew :app:assembleStandardRelease                    # 26 形态（Acrobits，App 仓内 acrobitsBridge 直连 cz.acrobits Maven 真身）
./gradlew :app:assembleStandardRelease -PuseNativeEngine  # native 形态（消费本 SDK 的 libs/*.aar）
```

两个形态的 App 源码都面向 `com.novosdk.*` 调用面（26 形态经 App 仓内
typealias 别名桥），业务代码零改动。

## 架构要点

四层单向依赖（外 → 内，无反向 import）：

1. **novosdk 形状面**（`com.novosdk` data/event/ali/support/key/mergeable）—
   纯契约层：接口形状与 Acrobits 一致，大量"恒返回占位实例 / no-op"的
   形状面方法（见各类 javadoc 声明），仅 Preferences/InstanceExt/
   TerminateTask 三个白名单点向下转发
2. **SdkBridge 桥**（`com.yeastar.sipcore`，位于 novosdk 模块）—
   引擎回调 → Listeners 分发 + Telecom 连接同步 + 账号持久化/冷恢复 +
   PUSH 模式后台生命周期（不可见即 un-REGISTER、回前台重注册）
3. **sip-core 引擎**（`SipWebrtcEngine` + 会话注册表）— 多通话会话化
   （上限 2），来电手动接听，SDP 黑盒透传（ICE/DTLS/SRTP 由 WebRTC aar
   承担，不进 pjmedia）；线程模型红线：全部状态收敛主线程 Handler
4. **native**（pjsip_jni.c + ys_pjsua_app.cpp）— JNI 桥 + pjsua 信令封装，
   `ys_*` 回调自 pjsua worker 线程 AttachCurrentThread 上抛

Telecom Self-Managed 四坑（extras 过滤 / OEM 自动 SCO / 特权路由压制 /
UI 快照刷新）的防御代码集中在 `SdkBridge` + `ConnectionImplApi23` +
`AudioRouteHelper`，注释含根因记录，改动前先读。

## ys_pjsua_app.{h,cpp} 双仓同步

pjsip 源码仓（novoone-app-sip，`pjsip-apps/src/pjsua/`）为源头，本目录
`sip-core/src/main/cpp/` 持编译副本——任一侧修改后必须同步其余各侧，
diff 逐字节一致（文件头有同步约定全文）。

## 与线上（Acrobits）行为差异声明

接口形状全量一致（App 零改动编译即证）；以下为行为面差异（多为
"App 写入/注册但本引擎静默不生效"）：

- **账户 XML 消费面**：App 创建账户写入 20+ 字段，本 SDK 消费 13 个
  （username/password/host/outboundProxy/authUsername/displayName/expires/
  transport/pushTokenReporterUrl/CustomHeaders/codecOrder/codecOrder3G/id）；
  opusOptions/ptime/SDES/DNS/rtcpMux/tryingTone/pushTokenReporter PostData/
  ContentType/Logging 等被忽略（无对应机制）
- **provisioning**：`Instance.init` 的 provisioning Xml 参数仅形状保留，
  内容不消费（verifyCerts=0 语义已体现在 TLS 证书校验关闭）
- **preferences 安慰剂字段**：trafficLogging / playbackBlockDuration /
  callIntegrationMode / echoSuppression / volumeBoost* 仅记录或转发日志，
  无引擎效果；userAgentOverride / incomingCallsMode 真生效
- **findSipHeader**：仅支持 X-Request-ID / X-Nov-Caller-ID-Name 两个头名
  （App 另查询的 X-Nov-Air-* 恒 null，静默不生效——与 iOS 同口径）
- **推送测试回调**：OnPushTestArrived / OnPushTestScheduled 形状面保留，
  本引擎无推送测试机制，永不回调
- **事件流**：EventStream.load 恒返回共享占位实例（无真实通话历史持久化）；
  MessageEvent 仅记录（无消息引擎）；铃声本地合成（无资源铃声文件）
- **会议组**：单腿组模型（每会话一组），Conferences.move/split 为 no-op；
  单账号引擎（getAccountCount 0/1）
- **Telecom**：注册即 self-managed（TelecomUtil.registerCallingAccount 的
  selfManaged 参数仅影响 highlightColor）；去电上报复用 addNewIncomingCall
  机制（self-managed 场景 placeCall 被系统静默拒绝）

## 已知限制

- 仅 `arm64-v8a`（WebRTC aar 与 pjsip 交付物均单 ABI）
- G729(18) 暂不支持（服务器配置含 G729 时静默过滤，纯 G729 段回退全
  4 编码——见 SipWebrtcEngine 编解码配置节）
- 蓝牙路由为 SCO/HFP 语义：A2DP-only 连接（无 HFP 的纯媒体耳机）列出
  蓝牙但无 SCO 通信设备可切——API 31+ 切换返回失败，API 26-30 的
  legacy 路径仅发异步请求无结果反馈（AudioRouteHelper.getAvailable 注释）
- 16KB 页对齐依赖 NDK r27 的显式链接参数（r28+ 可移除，见 CMakeLists）
