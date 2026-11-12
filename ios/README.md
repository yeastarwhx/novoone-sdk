# iOS 双引擎 SDK(novoone-app-sdk/ios)

iOS compat SDK:**NovoSDK 门面**(module `NovoSDK_Swift`、`NovoSDK*` 类名;方法签名形状对齐 Acrobits
便于 App 迁移)+ **自研 SipWebrtcEngine**。本地包 `NovoSDKSwiftPackage` 与
Acrobits 远程包不同名,双引擎切换由 switch_engine.py 双名字切换承担。

## 目录结构

```
ios/
├── CompatFW/                 # compat framework 源工程
│   ├── Sources/
│   │   ├── Facade/           # Acrobits 门面层(CompatBridge 8 子模块 / CompatAdapter / CompatCx)
│   │   └── SipCore/          # 自研引擎层(SipWebrtcEngine / SipCallKitCoordinator / pjsip 桥)
│   ├── Vendor/               # libpjsip-combined.a + WebRTC.xcframework(不入库,构建时就位)
│   ├── tools/gen_pbxproj.py  # pbxproj 生成(rglob 自动纳编 .swift/.mm/.cpp,加文件免维护工程)
│   └── Sources/SipCore/NovoSDK_Swift.modulemap  # 显式 modulemap(引擎 ObjC 头进 module,Swift 门面可见)
├── NovoSDKCompat/            # SPM 本地包壳(App 经它消费;包名 NovoSDKSwiftPackage)
│   ├── Binaries/             # NovoSDK_Swift.xcframework + WebRTC.xcframework(构建产物)
│   └── Package.swift
└── build-ios-sdk.sh          # 构建链:合静态库 → framework → xcframework → Binaries
```

## 构建

```bash
cd ios && ./build-ios-sdk.sh                 # 增量(复用 Vendor 静态库)
./build-ios-sdk.sh --rebuild-lib             # 强制重合 pjsip 静态库
./build-ios-sdk.sh --switch-native           # 构建后顺带切 App 工程到自研
```

依赖(缺省按 `~/Desktop/novosdk/{仓库名}` 布局,环境变量或参数覆盖:
`PJ_LIB_SRC` / `WEBRTC_XCFW_SRC` / `APP_IOS_DIR`,及 `--with-webrtc-src` / `--app-ios`):

- pjsip 静态库:`novoone-app-sip/demo/libs/` 下 `*.a`(宏开形态)
- WebRTC.xcframework:`CompatFW/Vendor/`(已就位则复用,缺省从 webrtc_checkout 拷贝)

产物:`NovoSDKCompat/Binaries/NovoSDK_Swift.xcframework`(末尾有 pj* 符号抽查输出)。

## 引擎切换(App 工程)

App 工程 `novoone-app/ios/NovoOneApp.xcodeproj` 的 pbxproj 在 **git 内恒为 Acrobits 形态**;
native 形态由脚本即时产生、**不提交**(回切即恢复基线)。
`switch_engine.py` 唯一真源在 App 仓(`ios/switch_engine.py`,随仓入库),SDK 仓不保留副本。

```bash
cd <novoone-app>/ios
python3 switch_engine.py native     # 切自研:saas 包引用(远程->本地 NovoSDKCompat)
                                    #   + productName 双名字变换 + MARKETING_VERSION 26.x -> 126.x
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
- 版本语义:**126.x = 自研引擎,26.x = Acrobits**(Bugly/系统设置可区分双装机)

## App 侧接入(native 形态)

- SPM 包:`NovoSDKSwiftPackage` 解析到 App 仓内 `ios/NovoSDKCompat`(本地包,
  由构建链 [6/6] 同步入库,不依赖 SDK 源码仓路径)
- App 源码 NovoSDK 命名:`import NovoSDK_Swift` + `NovoSDK*` 类名(方法签名形状对齐 Acrobits)
- App 工程编译流程不变(RN/Expo:`npm ci` + `pod install` + xcodebuild)
- 注意:clone 后首次 `pod install` 需重跑一次以生成 `ios/build/generated/ios`(RN codegen 时序),
  否则 `ReactAppDependencyProvider` 的 CpHeader 报 No such file or directory
- 注意:更换/重建 `Binaries/` 下 framework 后,若 App 编译报出与旧版 API 相关的
  幻影错误,删除 App 侧预编译 module 缓存后重编:
  `ios/build/Build/Intermediates.noindex/ExplicitPrecompiledModules/`、
  `SwiftExplicitPrecompiledModules/`(Xcode 版本新旧名并存)与
  `ios/build/Build/Intermediates.noindex/NovoOneApp.build/`(xcodebuild 会缓存旧
  swiftmodule/pcm 并复用,不随 SPM 产物自动失效;必要时连同
  `XCBuildData/` 三目录同删)
- 注意:**双引擎形态切换(26↔126)后首次构建**,除清缓存外还须
  `xcodebuild -resolvePackageDependencies`(SPM 包图缓存不随 pbxproj 切换刷新,
  报 `Unable to find module dependency`);**两种形态各用独立 derivedDataPath**
  (如 `build/claude-dd-26`=Acrobits / `build/claude-dd-native`=自研),共享
  derivedData 跨形态复用旧编译计划与 shim 残留,清缓存也救不回

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
- **SIP 密码 Keychain**(`CompatKeychain.swift`,对齐线上版行为):
  AccountSnapshot 落盘拆密码进独立 Keychain service(
  kSecAttrAccessibleAlwaysThisDeviceOnly——不进备份/不同步 iCloud/任何
  时刻可读保杀进程唤醒注册),UserDefaults 只存其余注册参数;读取边界拼回,
  Keychain 无密码 = 走无快照路径;登出双清;旧版 plist 明文一次性迁移
- **push 唤醒头撤除事件驱动**(对齐线上版行为):App 的 3s 盲定时
  exclude 落在注册在途/重试窗口时,撤除挂起至注册 200(重试 REGISTER 全程
  带头完成配对),45s 兜底防头永久粘性;新 push 重挂头时取消挂起;已注册
  成功时立即撤(与线上行为一致)

## 与线上(Acrobits)行为差异声明

线上 Acrobits SDK 的部分职责/行为在 compat 方案下形态不同,以下差异为有意设计
(非缺陷),团队维护时按此口径理解:

- **账户 XML 消费面**:App 登录链下发的账户 XML 节点 30+,compat 消费其中
  ~15 个(注册参数/pushTokenReporter*/铃声与音量等),其余节点静默忽略
  (Acrobits 下各有作用)。新增业务节点须先确认 compat 消费面再依赖
- **NovoSDKPreferences 安慰剂字段**:trafficLogging/echoSuppressionEnabled/
  volumeBoost*/userAgentOverride 赋值无效(引擎无消费点,见 CompatModels
  声明);includesCallKitCallsInRecent 真实生效
- **铃声源**:来电铃声/回铃音为本地合成 WAV(440+480Hz 双音电话频段,
  `SipRingtoneHelper`),不消费服务器/工程资源文件里的铃声配置(App 无此配置面)
- **`Vendor/pjsip-include/` 来源**:pjsip 公共头文件快照,拷贝自
  novoone-app-sip 仓(pjproject 2.17 WebRTC 集成模式),使 CompatFW 开箱
  可编;更新时从源头仓拷贝对应头文件并保持目录结构,diff 验证
  (ys_pjsua_app.{h,cpp} 双仓同步约定见文件头)

## 已知限制

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
  (与 Acrobits 版结构一致)

- INVITE 自定义头仅记录不上送(REGISTER 粘性头表已实装;对齐 Android 行为)
- 来电无 180 时停在 IncomingTrying(canBeAnswered 依赖)
- caller 字段缺失的 VoIP push 不 report CallKit
- CallRedirectCapabilities.canForward 恒 false(引擎无 Forward 动作)
- 三方会议 API(move/split)no-op(单腿组模型);attendedTransfer 走两腿挂断+桥接语义
- G729 依赖软编解码路径(bcg729 授权未落实)
