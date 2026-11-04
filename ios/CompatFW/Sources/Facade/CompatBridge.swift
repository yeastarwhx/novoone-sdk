//
//  CompatBridge.swift
//  CompatFW
//
//  Acrobits 兼容层:NovoSDKBridge / NovoSDKInstance / 8 个子模块门面。
//  API 形状逐字对齐 App 消费面;方法体经 CompatAdapter 接线
//  SipWebrtcEngine(= Android SdkBridge.java 语义)。
//

import Foundation

private func compatLog(_ message: String) {
    NSLog("[compat] %@", message)
}

/// compat 线程模型:CompatAdapter 及各子模块的全部簿记状态仅主线程读写。
/// App 的 RN 桥入口天然在 turbomodule queue(非主线程),facade 方法统一
/// 经此门 hop 到主线程;主线程时直通零开销。dispatch_sync(main) 的死锁
/// 前提是主线程反向 sync 等待 RN 队列——App 无此环,Acrobits 版同样要求
/// 门面内线程收敛(RN 线程 getActive 读 snapshots 与主线程
/// onCallSessionChanged 写并发会致 Dictionary COW 竞争 SIGSEGV)
@inline(__always)
func compatMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try body()
    }
    return try DispatchQueue.main.sync(execute: body)
}

/// Acrobits 基类形态保留(C++ 指针桥接痕迹,App 未直接消费)
@objcMembers public class BridgeClass: NSObject {
    public var instanceObject: UnsafeMutableRawPointer?
    @objc public func releaseInstance() -> UnsafeMutableRawPointer? {
        let pointer = instanceObject
        instanceObject = nil
        return pointer
    }
}

// MARK: - NovoSDKBridge

@objcMembers public final class NovoSDKBridge: NSObject {
    @objc public static var isDebug: Bool { false }
    @objc public static var build: UInt { 126 }
    @objc public static var isInitialized: Bool { NovoSDKBridge.shared != nil }

    /// 兼容 Acrobits initialize(license:error:);provisioning XML 由 compat 忽略
    @objc public static func initialize(_ license: String) throws {
        compatLog("initialize license=\(String(license.prefix(32)))...")
        try compatMain {
            guard shared == nil else {
                let error = NSError(domain: "NovoSDKInitErrorDomain", code: 102,
                                    userInfo: [NSLocalizedDescriptionKey: "already initialized"])
                throw error
            }
            shared = NovoSDKInstance()
        }
    }

    public static func instance() -> NovoSDKInstance {
        compatMain {
            if let instance = shared {
                return instance
            }
            // Acrobits 在未 initialize 时返回 nullptr 并断言;compat 放宽为惰性实例,
            // 引擎未初始化的行为由各子模块内部兜底(空集合/no-op + 日志)
            let instance = NovoSDKInstance()
            shared = instance
            return instance
        }
    }

    private static var shared: NovoSDKInstance?
}

// MARK: - NovoSDKInstance

@objcMembers public final class NovoSDKInstance: BridgeClass {
    private lazy var callsModule = NovoSDKInstanceCalls()
    private lazy var registrationModule = NovoSDKInstanceRegistration()
    private lazy var audioModule = NovoSDKInstanceAudio()
    private lazy var logModule = NovoSDKInstanceLog()
    private lazy var eventsModule = NovoSDKInstanceEvents()
    private lazy var notificationsModule = NovoSDKInstanceNotifications()
    private lazy var settingsModule = NovoSDKInstanceSettings()

    private var observerProxy: NovoSDKObserverProxyBridge?

    @objc public func setObserver(_ observer: NovoSDKObserverProxyBridge) {
        compatMain {
            observerProxy = observer
            // 引擎回调分发入口注册(CompatAdapter 持 weak,观察者生命周期由 App 管)
            CompatAdapter.shared.attach(observer: observer)
        }
        compatLog("setObserver")
    }

    @objc public func getObserver() -> NovoSDKObserverProxyBridge? {
        compatMain { observerProxy }
    }

    public func calls() -> NovoSDKInstanceCalls? { callsModule }
    public func registration() -> NovoSDKInstanceRegistration? { registrationModule }
    public func audio() -> NovoSDKInstanceAudio? { audioModule }
    public func log() -> NovoSDKInstanceLog? { logModule }
    public func events() -> NovoSDKInstanceEvents? { eventsModule }
    public func notifications() -> NovoSDKInstanceNotifications? { notificationsModule }
    public func settings() -> NovoSDKInstanceSettings? { settingsModule }
}

// MARK: - NovoSDKInstanceCalls

@objcMembers public final class NovoSDKInstanceCalls: BridgeClass {
    private lazy var conferencesModule = NovoSDKInstanceCallsConferences()

    public func conferences() -> NovoSDKInstanceCallsConferences? { conferencesModule }

    public func getActive() -> [NovoSDKCallEvent] {
        compatMain { CompatAdapter.shared.activeEvents() }
    }

    public func getState(_ call: NovoSDKCallEvent) -> CallStateType? {
        compatMain { CompatAdapter.shared.currentState(of: call) }
    }

    public func answerIncoming(call: NovoSDKCallEvent, media: CallDesiredMedia) -> Bool {
        compatMain { CompatAdapter.shared.answer(call) }
    }

    @discardableResult
    public func rejectIncomingHere(_ call: NovoSDKCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.reject(call) }
    }

    @discardableResult
    public func rejectIncomingEverywhere(_ call: NovoSDKCallEvent) -> Bool {
        // 单账户单腿:与 Here 等价
        compatMain { CompatAdapter.shared.reject(call) }
    }

    public func ignoreIncoming(_ call: NovoSDKCallEvent) -> Bool {
        compatLog("ignoreIncoming(App 未消费,引擎无对应动作,no-op)")
        return false
    }

    public func isAlive(_ call: NovoSDKCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.isAlive(call) }
    }

    public func setHeld(_ call: NovoSDKCallEvent, held: Bool) {
        compatMain { CompatAdapter.shared.setHeld(call, held: held) }
    }

    public func isHeld(_ call: NovoSDKCallEvent) -> CallHoldStates? {
        compatMain { CompatAdapter.shared.holdStates(of: call) }
    }

    public func close(_ call: NovoSDKCallEvent) {
        compatMain { CompatAdapter.shared.close(call) }
    }

    public func getStatistics(_ call: NovoSDKCallEvent) -> CallStatistics? {
        compatMain { CompatAdapter.shared.statistics(of: call) }
    }

    public func getMediaStatus(_ call: NovoSDKCallEvent) -> CallMediaStatus? {
        compatMain { CompatAdapter.shared.mediaStatus(of: call) }
    }

    public func getNetworkStatus(_ call: NovoSDKCallEvent) -> NovoSDKNetworkStatus? {
        compatMain { CompatAdapter.shared.networkStatus(of: call) }
    }

    public func findSipHeader(_ call: NovoSDKCallEvent, headerName: String) -> XmlTree? {
        compatMain { CompatAdapter.shared.findSipHeader(call, name: headerName) }
    }
}

// MARK: - NovoSDKInstanceCallsConferences(单腿组模型)

@objcMembers public final class NovoSDKInstanceCallsConferences: BridgeClass {
    public func list() -> [String] {
        compatMain { CompatAdapter.shared.groups() }
    }

    public func getCalls(conference: String) -> [NovoSDKCallEvent] {
        compatMain { CompatAdapter.shared.events(inGroup: conference) }
    }

    public func getCalls(call: NovoSDKCallEvent) -> [NovoSDKCallEvent] {
        compatMain {
            guard let group = CompatAdapter.shared.groupId(of: call) else { return [] }
            return CompatAdapter.shared.events(inGroup: group)
        }
    }

    public func get(_ call: NovoSDKCallEvent) -> String? {
        compatMain { CompatAdapter.shared.groupId(of: call) }
    }

    public func getSize(_ conference: String) -> Int {
        compatMain { CompatAdapter.shared.events(inGroup: conference).count }
    }

    public func getSize(call: NovoSDKCallEvent) -> Int {
        compatMain { CompatAdapter.shared.groupId(of: call) != nil ? 1 : 0 }
    }

    public func getActive() -> String? {
        compatMain { CompatAdapter.shared.activeGroup() }
    }

    @discardableResult
    public func setActive(_ conference: String?) -> Bool {
        compatMain { CompatAdapter.shared.setActiveGroup(conference) }
        return true
    }

    @discardableResult
    public func setActive(call: NovoSDKCallEvent) -> Bool {
        compatMain {
            guard let group = CompatAdapter.shared.groupId(of: call) else { return false }
            CompatAdapter.shared.setActiveGroup(group)
            return true
        }
    }

    @discardableResult
    public func move(call: NovoSDKCallEvent, conference: String) -> Bool {
        compatLog("no-op: move eventId=\(call.eventId) -> \(conference)(单腿组模型)")
        return false
    }

    @discardableResult
    public func move(call: NovoSDKCallEvent, target: NovoSDKCallEvent) -> Bool {
        compatLog("no-op: move(call:target:)(单腿组模型)")
        return false
    }

    public func split(call: NovoSDKCallEvent, activate: Bool) {
        compatLog("no-op: split eventId=\(call.eventId)(单腿组模型)")
    }

    public func transfer(call: NovoSDKCallEvent, target: NovoSDKCallEvent) {
        compatMain { CompatAdapter.shared.blindTransfer(from: call, to: target) }
    }

    @discardableResult
    public func attendedTransfer(call: NovoSDKCallEvent, target: NovoSDKCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.attendedTransfer(source: call, target: target) }
    }
}

// MARK: - NovoSDKInstanceEvents

@objcMembers public final class NovoSDKInstanceEvents: BridgeClass {
    public func post(_ event: NovoSDKEvent) -> EventsPostResult {
        compatMain { CompatAdapter.shared.postOutgoing(event) }
    }
}

// MARK: - NovoSDKInstanceLog

@objcMembers public final class NovoSDKInstanceLog: BridgeClass {
    private var sink: Serializer?
    private(set) var buffer: [String] = []
    private let lock = NSLock()

    public func setCustomSink(_ serializer: Serializer?) {
        lock.lock()
        defer { lock.unlock() }
        sink = serializer
    }

    func dispatchToSink(_ line: String) {
        lock.lock()
        let currentSink = sink
        buffer.append(line)
        lock.unlock()
        if let currentSink = currentSink,
           let data = line.data(using: .utf8) {
            currentSink.write(data)
        }
    }

    public func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.joined()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    public func seize() -> String {
        let content = get()
        clear()
        return content
    }

    public func log(_ entry: String) {
        dispatchToSink(entry)
    }
}

// MARK: - NovoSDKInstanceRegistration

@objcMembers public final class NovoSDKInstanceRegistration: BridgeClass {
    private(set) var cachedAccount: AccountXml?

    @discardableResult
    public func saveAccount(_ accountXml: XmlTree) -> String? {
        compatMain {
            guard CompatAdapter.shared.applyAccount(accountXml) != nil else {
                return nil
            }
            cachedAccount = AccountXml(xml: accountXml)
            return "sip"
        }
    }

    public func updateAll() {
        compatMain { CompatAdapter.shared.refreshRegistration() }
    }

    public func deleteAccount(id accountId: String) {
        compatLog("deleteAccount id=\(accountId)")
        compatMain {
            cachedAccount = nil
            CompatAdapter.shared.removeAccount()
        }
    }

    public func getRegistrationState(accountId: String) -> RegistratorStateType {
        compatMain { CompatAdapter.shared.currentRegistrationState() }
    }

    public func getAccount(accountId: String) -> AccountXml? {
        compatMain { cachedAccount ?? CompatAdapter.shared.cachedAccount() }
    }

    public func getAccounts() -> [String] {
        compatMain {
            (cachedAccount != nil || CompatAdapter.shared.cachedAccount() != nil) ? ["sip"] : []
        }
    }

    public func includeNonStandardSipHeader(accountId: String, method: String,
                                            responseCode: String, name: String, value: String) {
        compatMain { CompatAdapter.shared.includeHeader(method: method, name: name, value: value) }
    }

    public func excludeNonStandardSipHeader(accountId: String, method: String,
                                            responseCode: String, name: String) {
        compatMain { CompatAdapter.shared.excludeHeader(method: method, name: name) }
    }
}

// MARK: - NovoSDKInstanceAudio

@objcMembers public final class NovoSDKInstanceAudio: BridgeClass {
    public func isMuted() -> Bool {
        compatMain { CompatAdapter.shared.muteState() }
    }

    public func setMuted(_ muted: Bool) {
        compatMain { CompatAdapter.shared.setMuted(muted) }
    }

    public func getCallAudioRoute() -> AudioRouteType {
        compatMain { CompatAdapter.shared.currentRoute() }
    }

    public func setCallAudioRoute(route: AudioRouteType) {
        compatMain { CompatAdapter.shared.setRoute(route) }
    }

    public func dtmf(on key: Int8) {
        compatMain { CompatAdapter.shared.dtmf(key: key) }
    }

    public func dtmfOff() {
        compatLog("dtmfOff(iOS 无结束事件,空实现)")
    }
}

// MARK: - NovoSDKInstanceSettings / Notifications / Push

@objcMembers public final class NovoSDKInstanceSettings: BridgeClass {
    private lazy var preferences = NovoSDKPreferences()

    public func getPreferences() -> NovoSDKPreferences? {
        preferences
    }
}

@objcMembers public final class NovoSDKInstanceNotifications: BridgeClass {
    private lazy var pushModule = NovoSDKInstanceNotificationPush()

    public func push() -> NovoSDKInstanceNotificationPush? {
        pushModule
    }
}

@objcMembers public final class NovoSDKInstanceNotificationPush: BridgeClass {
    public func setRegistrationId(token: Data?, usage: PushTokenUsage) {
        // Acrobits 语义:SDK 记录 token 并在变化时经 Push Token Reporter
        // 自动上报(App 账户 XML 的 pushTokenReporter* 节点提供模板;配置
        // 未就绪时挂起,saveAccount 补发)
        CompatPushReporter.shared.setToken(token, usage: usage)
    }

    @discardableResult
    public func handle(_ message: XmlTree, usage: PushTokenUsage,
                       completion: ((NovoSDKPushNotificationCompletionInfo?) -> Void)?) -> ResourceHandle? {
        compatMain { CompatAdapter.shared.handlePush(message, usage: usage) }
        // App 侧 completion 传 nil 且线上实测不依赖(Acrobits 同行为);
        // 有传入则立即回执
        completion?(NovoSDKPushNotificationCompletionInfo())
        return ResourceHandle()
    }
}
