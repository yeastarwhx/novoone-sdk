//
//  CompatAdapter.swift
//  CompatFW
//
//  Acrobits 门面 ↔ SipWebrtcEngine 适配层(= Android SdkBridge.java 的 iOS 版)。
//  语义基线:SdkBridge.java(状态映射/单腿组/统计公式/REGISTER 头表/
//  AccountSnapshot 持久化全部对齐)。
//
//  线程纪律:引擎回调保证主线程(引擎内部收敛);门面方法由 App 主线程
//  调用——注册表仅主线程读写,不加锁。
//

import Foundation
import AVFoundation
import Network

// MARK: - 账户快照(持久化,推送唤醒冷启动重注册用;对齐 Android SharedPreferences)

struct AccountSnapshot {
    var host: String
    var username: String
    var password: String
    var authUser: String?
    var proxy: String?
    var displayName: String?
    var expires: Int
    var transport: SipTransportType
    var codecWifi: String?
    var codec3G: String?

    private static let storageKey = "compat.account.snapshot"

    static func load() -> AccountSnapshot? {
        guard let dict = UserDefaults.standard.dictionary(forKey: storageKey),
              let host = dict["host"] as? String,
              let username = dict["username"] as? String else {
            return nil
        }
        // 一次性迁移:旧形态 password 明文在 dict——拆进
        // Keychain 并重写剔除;幂等(迁移后 dict 无 password 键)
        if let legacy = dict["password"] as? String {
            CompatKeychain.setSipPassword(legacy)
            var migrated = dict
            migrated.removeValue(forKey: "password")
            UserDefaults.standard.set(migrated, forKey: storageKey)
        }
        // Keychain 读不到(未登录/已登出/系统异常)→ 返回 nil 走无快照
        // 路径,不以无凭证参数发起注册(对齐 dev-webrtc 219f069b 读取边界)
        guard let password = CompatKeychain.sipPassword(), !password.isEmpty else {
            return nil
        }
        return AccountSnapshot(
            host: host,
            username: username,
            password: password,
            authUser: dict["authUser"] as? String,
            proxy: dict["proxy"] as? String,
            displayName: dict["displayName"] as? String,
            expires: dict["expires"] as? Int ?? 300,
            transport: SipTransportType(rawValue: dict["transport"] as? Int ?? 1) ?? SipTransportType(rawValue: 1)!,
            codecWifi: dict["codecWifi"] as? String,
            codec3G: dict["codec3G"] as? String)
    }

    func save() {
        // 密码独立进 Keychain(219f069b 整改语义:plist 可被备份提取;
        // Keychain ThisDeviceOnly 硬件加密、不进备份/不同步 iCloud),
        // dict 只落其余注册参数
        CompatKeychain.setSipPassword(password)
        UserDefaults.standard.set([
            "host": host, "username": username,
            "authUser": authUser ?? "", "proxy": proxy ?? "",
            "displayName": displayName ?? "", "expires": expires,
            "transport": transport.rawValue,
            "codecWifi": codecWifi ?? "", "codec3G": codec3G ?? "",
        ], forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        // 登出双清:密码同步清出 Keychain
        CompatKeychain.clearSipPassword()
    }

    /// accountRegister 参数 dict(SipAccountParam* 契约)
    var registerParams: [AnyHashable: Any] {
        var params: [AnyHashable: Any] = [
            SipAccountParamServer: host,
            SipAccountParamUser: username,
            SipAccountParamPassword: password,
            SipAccountParamExpires: expires,
        ]
        if let authUser = authUser, !authUser.isEmpty {
            params[SipAccountParamAuthUser] = authUser
        }
        if let proxy = proxy, !proxy.isEmpty {
            params[SipAccountParamProxy] = proxy
        }
        if let displayName = displayName, !displayName.isEmpty {
            params[SipAccountParamDisplayName] = displayName
        }
        return params
    }
}

// MARK: - AccountXmlParser(白名单节点,其余记录忽略)

enum AccountXmlParser {
    static func parse(_ xml: XmlTree) -> AccountSnapshot? {
        func node(_ name: String) -> String? {
            let value = xml.getValueForNode(name)
            return value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        guard let username = node("username"), !username.isEmpty,
              let host = node("host"), !host.isEmpty else {
            return nil
        }

        // 传输:默认 tcp,对齐引擎"非法/缺省回退 TCP"
        let transport: SipTransportType
        switch (node("transport") ?? "tcp").lowercased() {
        case "udp": transport = SipTransportType(rawValue: 0)!
        case "tls": transport = SipTransportType(rawValue: 2)!
        default: transport = SipTransportType(rawValue: 1)!
        }

        var proxy: String?
        if (node("outboundProxy_enabled") ?? "0") == "1",
           let proxyHost = node("outboundProxy_host"), !proxyHost.isEmpty {
            proxy = proxyHost
        }

        let expires = Int(node("expires") ?? "") ?? 300

        let snapshot = AccountSnapshot(
            host: host,
            username: username,
            password: node("password") ?? "",
            authUser: node("authUsername"),
            proxy: proxy,
            displayName: node("title"),
            expires: expires > 0 ? expires : 300,
            transport: transport,
            codecWifi: node("codecOrder"),
            codec3G: node("codecOrder3G"))

        var ignored: [String] = []
        for childName in xml.children.map({ $0.name }) {
            switch childName {
            case "username", "host", "password", "authUsername", "transport",
                 "outboundProxy_enabled", "outboundProxy_host", "outboundProxy_transport",
                 "expires", "codecOrder", "codecOrder3G", "title":
                continue
            default:
                ignored.append(childName)
            }
        }
        if !ignored.isEmpty {
            NSLog("[compat] account ignored nodes: %@", ignored.joined(separator: ","))
        }
        return snapshot
    }
}

// MARK: - 状态映射(CallSession callStateView → CallStateType,对齐 Android mapState)

enum StateMapper {
    static func map(_ view: String?) -> CallStateType {
        switch view {
        case SipCallStateTrying: return .Trying
        case SipCallStateRinging: return .Ringing
        case SipCallStateEstablished: return .Established
        case SipCallStateIncomingTrying: return .IncomingTrying
        case SipCallStateIncomingRinging: return .IncomingRinging
        case SipCallStateIncomingAnswered:
            // 来电接通后引擎停在 IncomingAnswered;映射 Established
            // (App 收 Established 才启动计时/激活按钮——Android 同源注释)
            return .Established
        case SipCallStateIncomingRejected: return .IncomingRejected
        case SipCallStateIncomingMissed: return .IncomingMissed
        case SipCallStateTerminated:
            // 正常终态保持 Established,由 getActive 排除驱动终态处理
            // (映射 Error 会让 App 弹"通话异常"对话框)
            return .Established
        default:
            // Busy / Unauthorized / Error / 未知
            return .Error
        }
    }
}

// MARK: - CompatAdapter

final class CompatAdapter: NSObject, SipEngineCallback {

    static let shared = CompatAdapter()

    private let engine = SipWebrtcEngine.shared()

    /// 引擎侧 CONFIRMED 值(SipPjsuaStateConfirmed = 5;统计轮询判定用)
    private let pjsuaStateConfirmed = 5

    // ---- 注册表(主线程) ----

    /// sessionId → 门面事件对象(App 持续持有的同一实例,transients 存续)
    private var eventsBySession: [Int64: SoftphoneCallEvent] = [:]
    /// eventId → sessionId(App 调用入口反查)
    private var sessionByEvent: [UInt: Int64] = [:]
    /// sessionId → 引擎最近一次 session 快照字典
    private var snapshots: [Int64: [String: Any]] = [:]
    /// 已分发 onNewEvent 的会话
    private var announced: Set<Int64> = []
    /// 上次分发的本端 hold 状态(变化才发 onHoldStateChanged)
    private var lastLocalHold: [Int64: Bool] = [:]
    /// 活跃组(显式值;Acrobits 语义:组去激活=hold、激活=unhold,App 的
    /// hold 按钮经 toggleActiveGroup → setActive 驱动引擎 re-INVITE)
    private var activeGroupId: String?
    /// 最近一次激活的组(hold 踪迹:显式去激活后仍可定位"被挂起的组",
    /// 切换激活时对它补 hold)
    private var lastActiveGroupId: String?
    /// 是否被 App 显式 setActive 过(未显式时新会话自动激活,对齐
    /// Acrobits 新通话自动成为活跃组;显式去激活(hold)不自动复活)
    private var activeGroupExplicit = false
    /// 已排程终态清理的会话(终态推送后排程一次,防重复)
    private var terminatingSessions: Set<Int64> = []
    /// post 后待引擎 session 关联的呼出事件(队列:连续快速呼出)
    private var pendingOutgoing: [SoftphoneCallEvent] = []
    /// 缓存的注册状态
    private var registrationState: RegistratorStateType = .None
    /// REGISTER 自定义头表(粘性,对齐 Android mRegisterHeaders)
    private var registerHeaders: [String: String] = [:]
    /// 挂起撤除的头(头名→兜底定时器):App 的 3s 盲定时 exclude 落在注册
    /// 在途/重试窗口时,撤除延迟到注册 200;45s 兜底防头永久粘性
    private var pendingHeaderWithdrawals: [String: DispatchWorkItem] = [:]
    /// 统计缓存:sessionId → getCallQuality JSON 解析结果
    private var statsCache: [Int64: [String: Any]] = [:]
    private var statsTimer: Timer?
    /// 自动激活组的引擎动作踪迹(挤占保持/恢复,见 reconcileAutoHold;
    /// 区别于 activeGroup 的查询语义)
    private var autoActiveGroupId: String?

    /// 门面入口注册(App 经 SoftphoneInstance.setObserver 设置的观察者)
    private weak var observerProxy: SoftphoneObserverProxyBridge?

    private var networkMonitor: NWPathMonitor?
    private var lastNetworkType: NetworkType = .None
    /// 音频路由变化监听(AVAudioSession.routeChangeNotification)
    private var audioRouteObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    // MARK: 观察者接入

    func attach(observer: SoftphoneObserverProxyBridge) {
        observerProxy = observer
        startNetworkWatchIfNeeded()
        startAudioRouteWatchIfNeeded()
    }

    /// 音频路由变化转发(补齐 Acrobits onAudioRouteChanged 触发源):App 通话
    /// 页的路由显示/扬声器按钮可用性由 AudioServices 自探测快照驱动,蓝牙
    /// 通话接通瞬间的激活窗口会误报(audioExternal=false/audioRoute=
    /// Speaker),靠 SDK 路由回发刷新纠偏——compat 不转发 = UI 卡在快照
    /// (蓝牙显示扬声器、切换不刷新)。变化值取引擎 currentAudioRoute
    /// (拨号期门控 + 实际输出口探测,主线程契约)。主队列投递与 App 的
    /// refreshCallViews 主线程纪律对齐
    private func startAudioRouteWatchIfNeeded() {
        guard audioRouteObserver == nil else { return }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let route = AudioRouteType(rawValue: UInt(self.engine.currentAudioRoute())) ?? .Unselected
            self.dispatch { $0.onAudioRouteChanged?(route) }
        }
    }

    private func dispatch(_ block: (SoftphoneDelegateBridge) -> Void) {
        if let delegate = observerProxy?.delegate {
            block(delegate)
        }
    }

    // MARK: - 引擎生命周期与账户

    /// saveAccount:解析并持久化(注册在 updateAll 触发,对齐 App 调用时序)
    func applyAccount(_ xml: XmlTree) -> AccountSnapshot? {
        guard let snapshot = AccountXmlParser.parse(xml) else {
            NSLog("[compat] saveAccount: 缺 username/host,拒绝保存")
            return nil
        }
        snapshot.save()
        // Push Token Reporter 配置随账户 XML 下发(线上此职责由 Acrobits
        // SDK 内建,compat 承担;配置就绪后补发挂起的 token 上报)
        CompatPushReporter.shared.updateAccount(username: snapshot.username, xml: xml)
        return snapshot
    }

    /// updateAll:App 冷启动/网络恢复/前后台切换都会调——账号在册时必须走
    /// accountReregister(刷新注册),否则 accountRegister 的"先注销再注册"
    /// 会强拆进行中/振铃中的通话(引擎注释红线)
    func refreshRegistration() {
        guard let snapshot = AccountSnapshot.load() else {
            NSLog("[compat] updateAll: 无账户快照,跳过")
            return
        }
        engine.updateCodecConfig(snapshot.codecWifi, cellular: snapshot.codec3G)

        if !engine.isStarted() {
            applyUserAgentOverride()
            NSLog("[compat] updateAll: engineStart transport=%ld", snapshot.transport.rawValue)
            guard engine.engineStart(self, transport: snapshot.transport) else {
                publishRegisterState(.Error, message: "engine start failed")
                return
            }
            engine.accountRegister(snapshot.registerParams)
            publishRegisterState(.Registering)
            return
        }

        if engine.currentTransport() != snapshot.transport {
            NSLog("[compat] updateAll: transport %ld -> %ld,engineRestart",
                 engine.currentTransport().rawValue, snapshot.transport.rawValue)
            publishRegisterState(.Registering)
            engine.engineRestart(self, transport: snapshot.transport) { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.engine.accountRegister(snapshot.registerParams)
                } else {
                    self.publishRegisterState(.Error, message: "engine restart failed")
                }
            }
            return
        }

        if engine.hasRegisteredAccount() {
            engine.accountReregister()
        } else {
            engine.accountRegister(snapshot.registerParams)
            publishRegisterState(.Registering)
        }
    }

    func removeAccount() {
        AccountSnapshot.clear()
        CompatPushReporter.shared.clearAccount()
        engine.accountUnregister()
        publishRegisterState(.NotRegistered)
    }

    func currentRegistrationState() -> RegistratorStateType {
        registrationState
    }

    func cachedAccount() -> AccountXml? {
        guard let snapshot = AccountSnapshot.load() else { return nil }
        let xml = XmlTree(name: "account")
        xml.setNodeValue(value: snapshot.username, name: "username")
        xml.setNodeValue(value: snapshot.host, name: "host")
        xml.setNodeValue(value: snapshot.authUser ?? "", name: "authUsername")
        xml.setNodeValue(value: snapshot.proxy ?? "", name: "outboundProxy_host")
        xml.setNodeValue(value: String(snapshot.expires), name: "expires")
        xml.setNodeValue(value: transportName(snapshot.transport), name: "transport")
        xml.setNodeValue(value: snapshot.codecWifi ?? "", name: "codecOrder")
        xml.setNodeValue(value: snapshot.codec3G ?? "", name: "codecOrder3G")
        return AccountXml(xml: xml)
    }

    private func transportName(_ transport: SipTransportType) -> String {
        switch transport.rawValue {
        case 0: return "udp"
        case 2: return "tls"
        default: return "tcp"
        }
    }

    /// UA 设备段注入(App preferences.userAgentOverride = "Mobile/{v}-iOS-{uuid}"
    /// → 取尾段传引擎):推送路由按「REGISTER UA 设备段 ↔ PushReporter 上报
    /// userAgentId」关联,不同源 = VoIP push 零到达。必须 engineStart 前调
    private func applyUserAgentOverride() {
        guard let override = SoftphoneBridge.instance().settings()?.getPreferences()?.userAgentOverride,
              let deviceId = override.components(separatedBy: "iOS-").last,
              !deviceId.isEmpty else {
            return
        }
        SipWebrtcEngine.setUserAgentDeviceId(deviceId)
        NSLog("[compat] UA device segment injected (len=%ld)", deviceId.count)
    }

    // MARK: - VoIP push(CallKit report 红线 + 唤醒注册)

    /// push.handle:payload 字段契约(id/traceId/displayName/callerNumber,
    /// 取证自 RN 一阶段 AppDelegate)。report 先行(Apple 红线:push 回调
    /// 返回前必须发起 reportNewIncomingCall——coordinator 引擎 init 时已
    /// 就绪,不依赖 engineStart);唤醒注册异步,不阻塞 push 回调返回。
    /// caller 字段缺失(本地通知转发路径 NovoEngine.handleIncomingCall)
    /// 不 report——只有 VoIP 来电 push 才上系统卡片
    func handlePush(_ message: XmlTree, usage: PushTokenUsage) {
        guard usage == .IncomingCall || usage == .All else { return }
        let callerName = message.getValueForNode("displayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let callerNumber = message.getValueForNode("callerNumber")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pushId = message.getValueForNode("id")
        NSLog("[compat] push handle pushId=%@ caller=%@(%@)",
              pushId ?? "nil", callerName ?? "nil", callerNumber ?? "nil")
        if (callerNumber?.isEmpty ?? true) && (callerName?.isEmpty ?? true) {
            NSLog("[compat] push handle: 无 caller 字段,跳过 CallKit report")
        } else {
            // uuid 现场生成;CXCallUpdate 定制由 coordinator 内置
            //(对齐线上 Softphone_Cx_Delegate:分机 generic handle 等)
            engine.reportIncomingCall(nil, callerName: callerName, callerNumber: callerNumber)
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshRegistration()
        }
    }

    // MARK: REGISTER 头表(REGISTER 即时下发粘性,INVITE 仅记录——对齐 Android)

    func includeHeader(method: String, name: String, value: String?) {
        guard !name.isEmpty else { return }
        if method.caseInsensitiveCompare("REGISTER") == .orderedSame {
            registerHeaders[name] = value ?? ""
            // 新推送重挂头:取消该头的挂起撤除(旧唤醒链的撤除不得误撤
            // 新一轮唤醒头)
            pendingHeaderWithdrawals.removeValue(forKey: name)?.cancel()
            applyRegisterHeaders()
        } else {
            NSLog("[compat] %@ custom header recorded: %@=%@ (INVITE 头走呼叫路径参数)",
                  method, name, value ?? "")
        }
    }

    func excludeHeader(method: String, name: String) {
        guard !name.isEmpty else { return }
        if method.caseInsensitiveCompare("REGISTER") == .orderedSame {
            if registrationState == .Registered {
                // 已注册成功:push 配对已达成,立即撤(常规重注册不带唤醒头)
                registerHeaders.removeValue(forKey: name)
                applyRegisterHeaders()
                return
            }
            // 注册未成功(REGISTER 在途/失败重试中):挂起撤除——立即撤会让
            // 重试 REGISTER 无唤醒头、服务器无法配对 push,该通来电 INVITE
            // 不下发(弱网时序缺口,对齐 dev-webrtc abdf59e4 注册 200 事件
            // 驱动语义);45s 兜底防头永久粘性
            scheduleHeaderWithdrawal(name)
        }
    }

    private func applyRegisterHeaders() {
        let joined = registerHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        engine.setRegisterHeaders(joined.isEmpty ? nil : joined)
    }

    private func scheduleHeaderWithdrawal(_ name: String) {
        pendingHeaderWithdrawals[name]?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingHeaderWithdrawals.removeValue(forKey: name)
            self.registerHeaders.removeValue(forKey: name)
            self.applyRegisterHeaders()
            NSLog("[compat] reg header %@ withdrawn (45s fallback)", name)
        }
        pendingHeaderWithdrawals[name] = fallback
        // 45s ≈ 引擎 reg_retry(10s)4 轮窗口:持续失败期间 INVITE 不达即
        // 放弃该通,头随兜底撤除
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0, execute: fallback)
    }

    /// 注册 200:应用全部挂起撤除(重试 REGISTER 全程带头完成配对,成功即
    /// 撤;周期刷新等非唤醒场景挂起集为空,天然无动作)
    private func flushPendingHeaderWithdrawals() {
        guard !pendingHeaderWithdrawals.isEmpty else { return }
        for (name, timer) in pendingHeaderWithdrawals {
            timer.cancel()
            registerHeaders.removeValue(forKey: name)
        }
        let count = pendingHeaderWithdrawals.count
        pendingHeaderWithdrawals.removeAll()
        applyRegisterHeaders()
        NSLog("[compat] reg 200 — pending header withdrawals applied (%ld)", count)
    }

    // MARK: - 呼出链(post → startOutgoingCall)

    func postOutgoing(_ event: SoftphoneEvent) -> EventsPostResult {
        guard let call = event as? SoftphoneCallEvent, let number = call.uri, !number.isEmpty else {
            return .NoRecipient
        }
        guard engine.isStarted() else {
            NSLog("[compat] post -> uri=%@ rejected: engine not started", number)
            return .ProcessingFailed
        }
        let requestId = call.transients?.findString("requestId")
        NSLog("[compat] post -> startOutgoingCall uri=%@ requestId=%@", number, requestId ?? "nil")
        engine.startOutgoingCall(number, requestId: requestId)
        pendingOutgoing.append(call)
        return .Success
    }

    // MARK: - 会话查询(门面数据源)

    private func sessionId(of event: SoftphoneCallEvent) -> Int64? {
        sessionByEvent[event.eventId]
    }

    private func snapshot(of event: SoftphoneCallEvent) -> [String: Any]? {
        guard let sessionId = sessionId(of: event) else { return nil }
        return snapshots[sessionId]
    }

    private func callId(of event: SoftphoneCallEvent) -> Int? {
        guard let sessionId = sessionId(of: event),
              let callId = snapshots[sessionId]?[SipSessionKeyCallId] as? Int else {
            return nil
        }
        return callId >= 0 ? callId : nil
    }

    private func isTerminal(_ snapshot: [String: Any]) -> Bool {
        snapshot[SipSessionKeyIsTerminal] as? Bool ?? false
    }

    private func isIncoming(_ snapshot: [String: Any]) -> Bool {
        if let incoming = snapshot[SipSessionKeyIsIncoming] as? Bool {
            return incoming
        }
        return (snapshot[SipSessionKeyDirection] as? Int) == 1
    }

    private func activeSessionIds() -> [Int64] {
        snapshots.filter { !isTerminal($0.value) }.keys.sorted()
    }

    /// getActive 契约(Acrobits:getActiveCalls ≡ Conferences.getCalls(getActive)):
    /// 当前活跃组的非终态事件;组被去激活(hold)时为空——App 的 refresh
    /// 据此把 activeCall 回落到 callList 条目(组形态,findEntry 才能命中)
    func activeEvents() -> [SoftphoneCallEvent] {
        guard let group = activeGroup() else { return [] }
        return events(inGroup: group).filter { event in
            snapshot(of: event).map { !isTerminal($0) } ?? false
        }
    }

    /// getState 契约:最新快照视图状态映射(未知会话 nil)
    func currentState(of event: SoftphoneCallEvent) -> CallStateType? {
        guard let snapshot = snapshot(of: event) else { return nil }
        return StateMapper.map(snapshot[SipSessionKeyCallStateView] as? String)
    }

    /// isAlive 契约:事件仍在注册表(close 移除后失效)
    func isAlive(_ event: SoftphoneCallEvent) -> Bool {
        sessionId(of: event) != nil
    }

    // MARK: 组模型(单腿组:每会话一组,groupId = 引擎 session groupId)
    // 终态会话即时出列:App 的 callList 由 groups()/getCalls() 构建,RN
    // 通话面板靠 callList >0→0 关闭——终态组滞留列表 = 界面永远关不掉
    // (终态事件对象保留,App 的通话历史经事件流读取不受影响)

    func groups() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for sessionId in snapshots.keys.sorted() {
            guard let snapshot = snapshots[sessionId], !isTerminal(snapshot),
                  let group = snapshot[SipSessionKeyGroupId] as? String, !seen.contains(group) else {
                continue
            }
            seen.insert(group)
            ordered.append(group)
        }
        return ordered
    }

    func groupId(of event: SoftphoneCallEvent) -> String? {
        snapshot(of: event)?[SipSessionKeyGroupId] as? String
    }

    func events(inGroup groupId: String) -> [SoftphoneCallEvent] {
        snapshots.keys.sorted().compactMap { sessionId in
            guard let snapshot = snapshots[sessionId], !isTerminal(snapshot),
                  (snapshot[SipSessionKeyGroupId] as? String) == groupId else {
                return nil
            }
            return eventsBySession[sessionId]
        }
    }

    func activeGroup() -> String? {
        if let group = activeGroupId,
           snapshots.values.contains(where: {
               ($0[SipSessionKeyGroupId] as? String) == group && !isTerminal($0)
           }) {
            return group
        }
        // explicit 失稳兜底:显式状态的作用组(显式激活的 activeGroupId/
        // 被挂起的 lastActiveGroupId)均已终结时失效——新会话恢复自动
        // 激活。终态滞留窗口(引擎 1.5s+compat 3.5s 清理前)内挂断即重拨
        // 不等 removeSession 收口,读取点即时自愈;hold 态不误伤:作用组
        // 存活(hold≠终结)即保持(explicit 残留曾挡住新呼出自动激活,
        // 一接通即 hold 态)
        if activeGroupExplicit,
           (activeGroupId == nil || !groupAlive(activeGroupId!)),
           (lastActiveGroupId == nil || !groupAlive(lastActiveGroupId!)) {
            activeGroupExplicit = false
        }
        // 未显式设置(或显式组已终结):最新非终态组自动激活——对齐 Acrobits
        // "新通话自动成为活跃组";显式去激活(hold 态)不复活,保 toggle 语义
        guard !activeGroupExplicit else { return nil }
        return latestLiveGroupId()
    }

    /// 最新非终态组(sessionId 最大者;无存活会话返回 nil)
    private func latestLiveGroupId() -> String? {
        var latest: (Int64, String)?
        for (sessionId, snapshot) in snapshots where !isTerminal(snapshot) {
            if let group = snapshot[SipSessionKeyGroupId] as? String,
               latest == nil || sessionId > latest!.0 {
                latest = (sessionId, group)
            }
        }
        return latest?.1
    }

    /// 组内存活判定
    private func groupAlive(_ groupId: String) -> Bool {
        snapshots.values.contains {
            ($0[SipSessionKeyGroupId] as? String) == groupId && !isTerminal($0)
        }
    }

    /// 自动激活挤占的引擎动作:接通组切换时对原组补 hold、新组恢复
    /// unhold——对齐 Acrobits "新通话自动成为活跃,原通话自动保持;
    /// 挂断后自动恢复"。仅自动激活路径(显式状态下用户全权,不触碰);
    /// 挤占判定取**接通组**(振铃会话未接通不挤占,防呼入铃期误 hold
    /// 在通的通话;否则第二通接听后第一通未 hold,本机麦克双发两台全听到)
    private func reconcileAutoHold() {
        guard !activeGroupExplicit else { return }
        guard let current = confirmedLiveGroupId() else { return }
        if current != autoActiveGroupId {
            if let previous = autoActiveGroupId, groupAlive(previous), previous != current {
                setGroupHeld(previous, held: true)
            }
            setGroupHeld(current, held: false)
            autoActiveGroupId = current
            dispatch { $0.onCallRepositoryChanged?() }
        }
    }

    /// 最新含接通(CONFIRMED)会话的非终态组(无返回 nil)
    private func confirmedLiveGroupId() -> String? {
        var latest: (Int64, String)?
        for (sessionId, snapshot) in snapshots where !isTerminal(snapshot) {
            guard (snapshot[SipSessionKeyPjsuaState] as? Int) == pjsuaStateConfirmed,
                  let group = snapshot[SipSessionKeyGroupId] as? String else {
                continue
            }
            if latest == nil || sessionId > latest!.0 {
                latest = (sessionId, group)
            }
        }
        return latest?.1
    }

    /// Acrobits setActive 引擎语义:组去激活=hold、激活=unhold。
    /// App 的 hold/unhold 按钮(toggleActiveGroup)与单腿 unhold 恢复
    /// (toggleHoldForCall)都经此驱动引擎 re-INVITE。
    /// 挂起目标取 activeGroup()(实时值不依赖踪迹);unhold 无条件
    /// 发(同组恢复 previous==groupId 也要解 hold),幂等由 setGroupHeld
    /// 按快照 holdFlag 过滤
    func setActiveGroup(_ groupId: String?) {
        let previous = activeGroup()
        if let previous = previous, previous != groupId, groupAlive(previous) {
            setGroupHeld(previous, held: true)
        }
        if let groupId = groupId, groupAlive(groupId) {
            setGroupHeld(groupId, held: false)
        }
        activeGroupId = groupId
        activeGroupExplicit = true
        if let groupId = groupId {
            lastActiveGroupId = groupId
        } else if let previous = previous {
            // 显式去激活也留踪迹:explicit 的作用组=被挂起的组——hold 态
            // 据此保持(组活即不失效,见 activeGroup() 失稳兜底),组灭
            // 据此失效,explicit 不泄漏到下一通
            lastActiveGroupId = previous
        }
        // 激活态变化立即通知:App 组条目 isOnHold=!active,即时翻转
        // (不等引擎 holdFlag 回调——re-INVITE 往返百毫秒级,点击要即反馈)
        if previous != groupId {
            dispatch { $0.onCallRepositoryChanged?() }
        }
    }

    /// 组内全部非终态会话 setHeld(转发引擎 callHold);已达目标态的跳过
    /// (引擎 holdFlag 乐观置位,免重复 re-INVITE)
    private func setGroupHeld(_ groupId: String, held: Bool) {
        for (_, snapshot) in snapshots where !isTerminal(snapshot) {
            guard (snapshot[SipSessionKeyGroupId] as? String) == groupId,
                  let callId = snapshot[SipSessionKeyCallId] as? Int, callId >= 0 else {
                continue
            }
            if (snapshot[SipSessionKeyHoldFlag] as? Bool ?? false) == held {
                continue
            }
            engine.callHold(callId, held: held)
        }
    }

    // MARK: - 通话操作(门面转发)

    func answer(_ event: SoftphoneCallEvent) -> Bool {
        guard let snapshot = snapshot(of: event), !isTerminal(snapshot),
              let callId = callId(of: event) else {
            return false
        }
        engine.callAnswer(callId)
        return true
    }

    func reject(_ event: SoftphoneCallEvent) -> Bool {
        guard let snapshot = snapshot(of: event), !isTerminal(snapshot),
              let callId = callId(of: event) else {
            return false
        }
        engine.callReject(callId)
        return true
    }

    /// close:终态滞留会话 → 注册表移除(App 关闭结束页);非终态 → 挂断。
    /// INVITE 未提交(callId=-1)按 groupId 挂断(引擎 gather 窗口专用入口)
    func close(_ event: SoftphoneCallEvent) {
        guard let sessionId = sessionId(of: event),
              let snapshot = snapshots[sessionId] else { return }
        if isTerminal(snapshot) {
            removeSession(sessionId)
        } else if let callId = callId(of: event) {
            engine.callHangup(callId)
        } else if let group = snapshot[SipSessionKeyGroupId] as? String {
            engine.callHangup(byGroupId: group)
        }
    }

    private func removeSession(_ sessionId: Int64) {
        terminatingSessions.remove(sessionId)
        if let event = eventsBySession[sessionId] {
            sessionByEvent.removeValue(forKey: event.eventId)
        }
        eventsBySession.removeValue(forKey: sessionId)
        snapshots.removeValue(forKey: sessionId)
        announced.remove(sessionId)
        lastLocalHold.removeValue(forKey: sessionId)
        statsCache.removeValue(forKey: sessionId)
        // 关联组若无存活会话,清组激活踪迹——下一通新会话可重新自动激活
        // (显式去激活即 hold 态时 activeGroupId 为 nil,踪迹在 lastActiveGroupId)。
        // 组全灭三态一并重置:自动激活态下直接点 hold 后挂断的路径
        // (activeGroupId/lastActiveGroupId 均空、explicit=true)两个分支
        // 都不进,explicit 残留会永久挡住新通话自动激活——新呼出一接通
        // 即 hold 态、hold 计时在走且不自愈
        if latestLiveGroupId() == nil
            || (activeGroupId != nil && !groupAlive(activeGroupId!)) {
            activeGroupId = nil
            lastActiveGroupId = nil
            activeGroupExplicit = false
            autoActiveGroupId = nil
        } else if activeGroupId == nil, let last = lastActiveGroupId, !groupAlive(last) {
            lastActiveGroupId = nil
            activeGroupExplicit = false
        }
        // 移除即通知:close() 终态分支(App 对已死通话按挂断)与滞留清理
        // 都经此收口——不通知则 RN 停在旧 callList,面板关不掉
        dispatch { $0.onCallRepositoryChanged?() }
    }

    func setHeld(_ event: SoftphoneCallEvent, held: Bool) {
        guard let callId = callId(of: event) else { return }
        engine.callHold(callId, held: held)
    }

    func holdStates(of event: SoftphoneCallEvent) -> CallHoldStates? {
        guard let snapshot = snapshot(of: event) else { return nil }
        return CallHoldStates(
            local: (snapshot[SipSessionKeyHoldFlag] as? Bool ?? false) ? .Held : .Active,
            remote: (snapshot[SipSessionKeyRemoteHoldFlag] as? Bool ?? false) ? .Held : .Active)
    }

    func muteState() -> Bool {
        for sessionId in activeSessionIds() {
            if (snapshots[sessionId]?[SipSessionKeyMuteFlag] as? Bool) == true {
                return true
            }
        }
        return false
    }

    func setMuted(_ muted: Bool) {
        for sessionId in activeSessionIds() {
            guard let callId = snapshots[sessionId]?[SipSessionKeyCallId] as? Int, callId >= 0 else {
                continue
            }
            engine.callMute(callId, muted: muted)
        }
    }

    func dtmf(key: Int8) {
        guard let sessionId = activeSessionIds().first,
              let callId = snapshots[sessionId]?[SipSessionKeyCallId] as? Int, callId >= 0 else {
            return
        }
        let scalar = UnicodeScalar(UInt8(bitPattern: key))
        engine.callDtmf(callId, digits: String(Character(scalar)))
    }

    func blindTransfer(from event: SoftphoneCallEvent, to target: SoftphoneCallEvent) {
        guard let callId = callId(of: event),
              let number = target.uri, !number.isEmpty else { return }
        engine.callXfer(callId, to: number)
    }

    @discardableResult
    func attendedTransfer(source: SoftphoneCallEvent, target: SoftphoneCallEvent) -> Bool {
        guard let sourceCallId = callId(of: source), let targetCallId = callId(of: target) else {
            return false
        }
        engine.callXferAttended(sourceCallId, destCallId: targetCallId)
        return true
    }

    /// 咨询转可选目标:其他非终态会话(单腿组模型,不含 source 自身)
    func redirectTargets(excluding source: SoftphoneCallEvent) -> [SoftphoneCallEvent] {
        guard let sourceSessionId = sessionId(of: source) else { return [] }
        return activeSessionIds().compactMap { sessionId in
            sessionId == sourceSessionId ? nil : eventsBySession[sessionId]
        }
    }

    // MARK: - SIP 头查询(findSipHeader:引擎缓存字段映射,终态关闭)

    func findSipHeader(_ event: SoftphoneCallEvent, name: String) -> XmlTree? {
        guard let snapshot = snapshot(of: event), !isTerminal(snapshot) else { return nil }
        let value: String?
        switch name {
        case "X-REQUEST-ID":
            value = (snapshot[SipSessionKeyRequestId] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case "X-Nov-Caller-ID-Name":
            value = (snapshot[SipSessionKeyCallerIdName] as? String).flatMap { $0.isEmpty ? nil : $0 }
        default:
            value = nil
        }
        guard let value = value else { return nil }
        let node = XmlTree(name: name)
        node.data = value
        return node
    }

    // MARK: - 统计(getCallQuality 异步 → 缓存 → 同步读,公式对齐 Android)

    /// App 侧强解包返回值(NovoEngine.getStatistics 的 `!`)——永不返回 nil
    func statistics(of event: SoftphoneCallEvent) -> CallStatistics {
        let stats = sessionId(of: event).flatMap { statsCache[$0] }
        let jitterMs = (stats?["jitterMs"] as? Double) ?? 0
        let lossPct = (stats?["packetLossPct"] as? Double) ?? 0
        let rttMs = (stats?["roundTripMs"] as? Double) ?? 0
        let st = CallStatistics()
        st.clockRateInHertz = 48000
        // App 侧 jitterMs = maxJitter*1000/clockRate,48 系数还原毫秒值
        st.maxJitter = (jitterMs * 48).rounded()
        st.jitterBufferPacketLossPercentage = lossPct >= 0 ? Int(lossPct.rounded()) : 0
        st.meteredNetworkJitter = Int64(jitterMs * 1000)
        st.avgRoundTripTimeInMilliseconds = rttMs >= 0 ? Int(rttMs.rounded()) : -1
        return st
    }

    func mediaStatus(of event: SoftphoneCallEvent) -> CallMediaStatus? {
        guard let sessionId = sessionId(of: event),
              let snapshot = snapshots[sessionId] else { return nil }
        let status = CallMediaStatus()
        status.active = !isTerminal(snapshot)
        status.audio?.outgoingPayloadFriendlyName = statsCache[sessionId]?["codec"] as? String
        return status
    }

    /// 网络接口名:取自通话质量轮询快照(getCallQuality JSON 的 network 字段,
    /// 引擎 currentNetworkName:Wi-Fi/cellular);无快照(非通话中)返回 nil
    func networkStatus(of event: SoftphoneCallEvent) -> SoftphoneNetworkStatus? {
        guard let sessionId = sessionId(of: event),
              let network = statsCache[sessionId]?["network"] as? String else {
            return nil
        }
        return SoftphoneNetworkStatus(networkInterfaceName: network.isEmpty ? nil : network)
    }

    /// CONFIRMED 会话存在时开 1s 轮询(主线程;对齐 Android ensureStatsPolling)
    private func refreshStatsPolling() {
        let hasConfirmed = snapshots.values.contains { snapshot in
            guard !isTerminal(snapshot),
                  let callId = snapshot[SipSessionKeyCallId] as? Int, callId >= 0 else {
                return false
            }
            return (snapshot[SipSessionKeyPjsuaState] as? Int) == pjsuaStateConfirmed
        }
        if hasConfirmed {
            if statsTimer == nil {
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.pollStatsOnce()
                }
                RunLoop.main.add(timer, forMode: .common)
                statsTimer = timer
            }
        } else if let timer = statsTimer {
            timer.invalidate()
            statsTimer = nil
        }
    }

    private func pollStatsOnce() {
        var polled = false
        for (sessionId, snapshot) in snapshots {
            guard !isTerminal(snapshot),
                  let callId = snapshot[SipSessionKeyCallId] as? Int, callId >= 0,
                  (snapshot[SipSessionKeyPjsuaState] as? Int) == pjsuaStateConfirmed else {
                continue
            }
            polled = true
            engine.getCallQuality(callId) { [weak self] json in
                DispatchQueue.main.async {
                    guard let self = self, let json = json, !json.isEmpty,
                          let data = json.data(using: .utf8),
                          let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return
                    }
                    self.statsCache[sessionId] = stats
                }
            }
        }
        if !polled, let timer = statsTimer {
            timer.invalidate()
            statsTimer = nil
        }
    }

    // MARK: - 音频路由

    func currentRoute() -> AudioRouteType {
        return AudioRouteType(rawValue: UInt(engine.currentAudioRoute())) ?? .Unselected
    }

    func setRoute(_ route: AudioRouteType) {
        _ = engine.setAudioRoute(Int(route.rawValue))
    }

    // MARK: - 网络变化分发(onNetworkChangeDetected)

    private func startNetworkWatchIfNeeded() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let type: NetworkType
            if path.usesInterfaceType(.wifi) {
                type = .Wifi
            } else if path.usesInterfaceType(.cellular) {
                type = .Cellular
            } else {
                type = .None
            }
            DispatchQueue.main.async {
                guard let self = self, type != self.lastNetworkType else { return }
                self.lastNetworkType = type
                self.dispatch { $0.onNetworkChangeDetected?(type) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "compat.network.watch"))
        networkMonitor = monitor
    }

    // MARK: - SipEngineCallback(引擎主线程)

    func onCallSessionChanged(_ session: [AnyHashable: Any]?) {
        guard let session = session as? [String: Any],
              let sessionId = session[SipSessionKeySessionId] as? Int64 else {
            return
        }
        snapshots[sessionId] = session

        // 终态到达:组即时出列(groups/getCalls 过滤)驱动面板收口;
        // 滞留窗口后清簿记(对齐引擎 terminalLinger=1500ms 后 purge 的
        // 节奏,窗口内 App 仍可读终态快照)
        if isTerminal(session), !terminatingSessions.contains(sessionId) {
            terminatingSessions.insert(sessionId)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(3500)) { [weak self] in
                self?.removeSession(sessionId)
            }
        }

        var event = eventsBySession[sessionId]
        if event == nil {
            event = bindOrSpawnEvent(sessionId: sessionId, session: session)
        }
        guard let callEvent = event else { return }
        syncEventFields(callEvent, session: session)

        if !announced.contains(sessionId) {
            announced.insert(sessionId)
            dispatch { $0.onNewEvent?(callEvent) }
        }

        let state = StateMapper.map(session[SipSessionKeyCallStateView] as? String)
        dispatch { $0.onCallStateChanged?(state: state, call: callEvent) }

        let held = session[SipSessionKeyHoldFlag] as? Bool ?? false
        if lastLocalHold[sessionId] != held {
            lastLocalHold[sessionId] = held
            let states = CallHoldStates(
                local: held ? .Held : .Active,
                remote: (session[SipSessionKeyRemoteHoldFlag] as? Bool ?? false) ? .Held : .Active)
            dispatch { $0.onHoldStateChanged?(states: states, call: callEvent) }
        }

        dispatch { $0.onCallRepositoryChanged?() }
        reconcileAutoHold()
        refreshStatsPolling()
    }

    func onRegisterState(_ status: Int32, text: String?) {
        switch Int(status) {
        case 200:
            publishRegisterState(.Registered)
            // 注册成功(含重试后成功):撤除挂起的唤醒头(弱网重试全程带头
            // 完成配对)+ 补触发 token 上报(确保注册后服务端可关联)
            flushPendingHeaderWithdrawals()
            CompatPushReporter.shared.reportOnRegistered()
        case 401:
            publishRegisterState(.Unauthorized, message: "(401) \(text ?? "")")
        case 403:
            publishRegisterState(.Error, message: "(403) \(text ?? "")")
        default:
            // 中间态/超时重试:App 只认 Registered 为成功,其余维持 Registering
            publishRegisterState(.Registering)
        }
    }

    func onIncomingCall(_ session: [AnyHashable: Any]?) {
        guard let session = session as? [String: Any],
              let sessionId = session[SipSessionKeySessionId] as? Int64 else {
            return
        }
        snapshots[sessionId] = session
        if eventsBySession[sessionId] == nil {
            _ = bindOrSpawnEvent(sessionId: sessionId, session: session)
        }
        guard let event = eventsBySession[sessionId] else { return }
        syncEventFields(event, session: session)
        if !announced.contains(sessionId) {
            announced.insert(sessionId)
            dispatch { $0.onNewEvent?(event) }
        }
        // 来电首状态走同一分发链(IncomingTrying → 180 后 IncomingRinging)
        let state = StateMapper.map(session[SipSessionKeyCallStateView] as? String)
        dispatch { $0.onCallStateChanged?(state: state, call: event) }
        dispatch { $0.onCallRepositoryChanged?() }
    }

    func onLog(_ level: Int32, message: String?) {
        guard let message = message, !message.isEmpty else { return }
        SoftphoneBridge.instance().log()?.dispatchToSink(message)
    }

    func onCallKitEvent(_ event: [AnyHashable: Any]?) {
        // CallKit 动作事件由 Softphone_Cx/Coordinator 链消费(Phase 4),不外发
    }

    // MARK: - 状态发布

    private func publishRegisterState(_ state: RegistratorStateType, message: String? = nil) {
        registrationState = state
        dispatch { $0.onRegistrationStateChanged?(state: state, accountId: "sip") }
        if let message = message {
            dispatch { $0.onRegistrationErrorMessage?(message: message, accountId: "sip") }
        }
    }

    // MARK: - 事件绑定与字段同步

    private func bindOrSpawnEvent(sessionId: Int64, session: [String: Any]) -> SoftphoneCallEvent? {
        let incoming = isIncoming(session)
        let event: SoftphoneCallEvent
        if !incoming, !pendingOutgoing.isEmpty {
            event = pendingOutgoing.removeFirst()
        } else {
            event = SoftphoneCallEvent.create()
            event.accountId = "sip"
            if incoming, let number = session[SipSessionKeyRemoteNumber] as? String {
                event.remoteUsers = [SoftphoneRemoteUser(genericUri: number, displayName: nil)]
            }
        }
        eventsBySession[sessionId] = event
        sessionByEvent[event.eventId] = sessionId
        return event
    }

    private func syncEventFields(_ event: SoftphoneCallEvent, session: [String: Any]) {
        let incoming = isIncoming(session)
        event.direction = incoming ? .Incoming : .Outgoing
        if let number = session[SipSessionKeyRemoteNumber] as? String {
            let callerIdName = session[SipSessionKeyCallerIdName] as? String
            if event.remoteUsers.isEmpty {
                event.remoteUsers = [SoftphoneRemoteUser(genericUri: number, displayName: callerIdName)]
            } else {
                event.remoteUsers[0].genericUri = number
                if let callerIdName = callerIdName, !callerIdName.isEmpty {
                    event.remoteUsers[0].displayName = callerIdName
                }
            }
            // 展示名兜底:callerIdName 缺失(呼出场景服务器不给 From 显示名)
            // 时填号码——App 组条目 account=displayName,HoldBar 对空 account
            // 显示「未知联系人」(号码不作 fallback);来电有 callerIdName 不受
            // 影响
            if (event.remoteUsers[0].displayName ?? "").isEmpty {
                event.remoteUsers[0].displayName = number
            }
        }
        // 引擎快照 callStartTime 为毫秒(SipCurrentTimeMillis);timeEstablished
        // 契约同样毫秒(对齐 Acrobits/Android TimePoint.toMilliseconds,App 的
        // callStartTime 直接消费该值)——不做 /1000 秒换算
        if let callStart = session[SipSessionKeyCallStartTime] as? Int64, callStart > 0,
            event.timeEstablished == 0 {
            event.markEstablished(at: Double(callStart))
        }
        // 来电 requestId 物化进 transients(呼出 requestId App 已在 post 前写入)
        if incoming, let requestId = session[SipSessionKeyRequestId] as? String, !requestId.isEmpty {
            if event.transients == nil {
                event.transients = JsonDict()
            }
            if (event.transients?.findString("requestId")) == nil {
                event.transients?.set(requestId, forKey: "requestId")
            }
        }
        let createdAt = session[SipSessionKeyCreatedAt] as? Int64 ?? 0
        if createdAt > 0 {
            event.timestamp = Double(createdAt) / 1000.0
        }
    }
}
