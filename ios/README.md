# iOS 双引擎 SDK(novoone-sdk/ios)

iOS compat SDK:以 **Acrobits 兼容门面**(Softphone_Swift 类名/方法签名逐字对齐)+ **自研 SipWebrtcEngine**
替换 Acrobits SoftphoneSwiftPackage-saas,App 工程零改动切换。

## 目录结构

```
ios/
├── CompatFW/                 # compat framework 源工程
│   ├── Sources/
│   │   ├── Facade/           # Acrobits 门面层(CompatBridge 8 子模块 / CompatAdapter / CompatCx)
│   │   └── SipCore/          # 自研引擎层(SipWebrtcEngine / SipCallKitCoordinator / pjsip 桥)
│   ├── Vendor/               # libpjsip-combined.a + WebRTC.xcframework(不入库,构建时就位)
│   ├── tools/gen_pbxproj.py  # pbxproj 生成(rglob 自动纳编 .swift/.mm/.cpp,加文件免维护工程)
│   └── Softphone_Swift.modulemap  # 显式 modulemap(引擎 ObjC 头进 module,Swift 门面可见)
├── SoftphoneCompat/          # SPM 本地包壳(App 经它消费;product/target 名与 Acrobits 一致)
│   ├── Binaries/             # Softphone_Swift.xcframework + WebRTC.xcframework(构建产物)
│   └── Package.swift
├── build-ios-sdk.sh          # 构建链:合静态库 → framework → xcframework → Binaries
└── switch_engine.py          # App 工程引擎切换(native/acrobits/status/selftest)
```

## 构建

```bash
cd ios && ./build-ios-sdk.sh                 # 增量(复用 Vendor 静态库)
./build-ios-sdk.sh --rebuild-lib             # 强制重合 pjsip 静态库
./build-ios-sdk.sh --switch-native           # 构建后顺带切 App 工程到自研
```

依赖(缺省路径,可用参数覆盖):

- pjsip 静态库:`novoone-app/ios/SipCore/pjsip-ios/lib/` 下 `*.a`(宏开形态)
- WebRTC.xcframework:`novoone-app/ios/SipCore/Frameworks/WebRTC.xcframework`

产物:`SoftphoneCompat/Binaries/Softphone_Swift.xcframework`(末尾有 pj* 符号抽查输出)。

## 引擎切换(App 工程)

App 工程 `novoone-app/ios/NovoOneApp.xcodeproj` 的 pbxproj 在 **git 内恒为 Acrobits 形态**;
native 形态由脚本即时产生、**不提交**(回切即恢复基线)。

```bash
python3 switch_engine.py native     # 切自研:saas 包引用(远程->本地 SoftphoneCompat)
                                    #   + NovoOneApp MARKETING_VERSION 26.9.x -> 126.9.x
python3 switch_engine.py acrobits   # 回 Acrobits:git restore 恢复 HEAD 基线(不做文本逆变换)
python3 switch_engine.py status     # 当前引擎 / 版本 / pbxproj 状态
python3 switch_engine.py selftest   # 对 git HEAD 基线跑 native 变换自检(只读)
```

规则(任务决策):

- 仅操作 **NovoOneApp** target 的 saas 包引用与 MARKETING_VERSION;**OEM(saas-video 包)不动**
- `native` 拒绝从脏 pbxproj 出发(防把人工改动卷进脚本产物);已是 native 时幂等提示
- `acrobits` = `git restore`:xcodebuild 会规范化重写 pbxproj(拆 section/注释与 URL
  改写/加引号),文本逆变换在新格式上必然失配,故直接恢复 HEAD 基线;acrobits 态下
  pbxproj 脏(疑似人工改动)时拒绝自动恢复,提示人工处理
- 版本语义:**126.9.x = 自研引擎,26.9.x = Acrobits**(Bugly/系统设置可区分双装机)

## App 侧接入(native 形态)

- SPM 包:`SoftphoneSwiftPackage-saas` 解析到 `../../novoone-sdk/ios/SoftphoneCompat`(本地)
- App 源码零改动:import / 类名 / 方法签名均与 Acrobits 一致
- App 工程编译流程不变(RN/Expo:`npm ci` + `pod install` + xcodebuild)
- 注意:clone 后首次 `pod install` 需重跑一次以生成 `ios/build/generated/ios`(RN codegen 时序),
  否则 `ReactAppDependencyProvider` 的 CpHeader 报 No such file or directory
- 注意:更换/重建 `Binaries/` 下 framework 后,若 App 编译报出与旧版 API 相关的
  幻影错误,删除 App 侧预编译 module 缓存后重编:
  `ios/build/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/` 与
  `ios/build/Build/Intermediates.noindex/NovoOneApp.build/`(xcodebuild 会缓存旧
  swiftmodule/pcm 并复用,不随 SPM 产物自动失效)

## Acrobits 内建职责的 compat 承担

线上版三项职责原由 Acrobits SDK 内建,compat 方案下由 compat 实现(App 侧零改动):

- **Push Token Reporter**(`CompatPushReporter.swift`):App 经账户 XML 下发
  `pushTokenReporter*` 节点(占位符模板),compat 在 token 变化
  (setRegistrationId)/配置就绪(saveAccount)/注册 200 三源触发上报
  (1s 去抖合并);报文契约对齐 E3 实测:token=base64(Data)、selector=
  40HEX:8HEX 装机一次生成(`compat.push.selector` 键)、2xx 成功、4xx 不
  重试、网络/5xx 退避 1s/4s/16s;配置未就绪挂起(冷启动 push 唤醒先于
  登录链属正常时序)。日志经 SipCoreLogger 双写落 Sip.log(前缀
  `[compat] [PUSH-REPORT]`)
- **SIP 密码 Keychain**(`CompatKeychain.swift`,对齐 dev-webrtc 219f069b):
  AccountSnapshot 落盘拆密码进独立 Keychain service(
  kSecAttrAccessibleAlwaysThisDeviceOnly——不进备份/不同步 iCloud/任何
  时刻可读保杀进程唤醒注册),UserDefaults 只存其余注册参数;读取边界拼回,
  Keychain 无密码 = 走无快照路径;登出双清;旧版 plist 明文一次性迁移
- **push 唤醒头撤除事件驱动**(对齐 dev-webrtc abdf59e4):App 的 3s 盲定时
  exclude 落在注册在途/重试窗口时,撤除挂起至注册 200(重试 REGISTER 全程
  带头完成配对),45s 兜底防头永久粘性;新 push 重挂头时取消挂起;已注册
  成功时立即撤(与线上行为一致)

## 已知限制(一期)

- 组激活语义(compat conferences 模型,对齐 Acrobits,App 按钮链依赖):
  - 新会话自动成为活跃组(无显式 setActive 时激活最新非终态组);
  - `setActive(nil)`=组挂起(引擎 hold re-INVITE)、`setActive(g)`=组恢复(unhold,
    切换时对原组补 hold)——App 的 hold/unhold 按钮(toggleActiveGroup)经此驱动引擎;
    激活态变化即时回调(不等引擎 re-INVITE 往返,UI 即时反馈),hold/unhold 幂等
    (按引擎 holdFlag 乐观置位过滤重复 re-INVITE);
  - `calls().getActive()` 返回**活跃组**的通话(组挂起时为空),App 的 activeCall
    据此回落 callList 组形态条目,findEntry(groupId) 才能命中。注意:Android compat
    无此语义(App 走 Entry.call 全对象 fastjson 序列化路径,iOS App 机制不同所致)
  - 终态会话即时出 conferences 列表(groups/getCalls/getSize 过滤终态)——App 的
    callList 由 conferences 构建,RN 面板靠 callList >0→0 关闭,终态组滞留 = 界面
    关不掉;滞留 3.5s(引擎 terminalLinger 1500ms+余量)后清 compat 簿记,终态
    事件对象保留(通话历史经事件流读取不受影响)
- CallKit 系统界面的 hold(经 SipCallKitCoordinator 直调引擎)不联动组激活状态
  (与 Acrobits 版结构一致);INVITE 自定义头仅记录不上送(对齐 Android 一期行为)

- INVITE 自定义头仅记录不上送(REGISTER 粘性头表已实装;对齐 Android 一期行为)
- 来电无 180 时停在 IncomingTrying(canBeAnswered 依赖)
- caller 字段缺失的 VoIP push 不 report CallKit
- CallRedirectCapabilities.canForward 恒 false(引擎无 Forward 动作)
- 三方会议 API(move/split)no-op(单腿组模型);attendedTransfer 走两腿挂断+桥接语义
- G729 依赖软编解码路径(bcg729 授权是二期议题)
