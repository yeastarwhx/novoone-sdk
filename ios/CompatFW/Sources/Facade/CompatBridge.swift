//
//  CompatBridge.swift
//  CompatFW
//
//  Acrobits 兼容层:SoftphoneBridge / SoftphoneInstance / 8 个子模块门面。
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

// MARK: - SoftphoneBridge

@objcMembers public final class SoftphoneBridge: NSObject {
    @objc public static var isDebug: Bool { false }
    @objc public static var build: UInt { 126 }
    @objc public static var isInitialized: Bool { SoftphoneBridge.shared != nil }

    /// 兼容 Acrobits initialize(license:error:);provisioning XML 由 compat 忽略
    @objc public static func initialize(_ license: String) throws {
        compatLog("initialize license=\(String(license.prefix(32)))...")
        try compatMain {
            guard shared == nil else {
                let error = NSError(domain: "SoftphoneInitErrorDomain", code: 102,
                                    userInfo: [NSLocalizedDescriptionKey: "already initialized"])
                throw error
            }
            shared = SoftphoneInstance()
        }
    }

    public static func instance() -> SoftphoneInstance {
        compatMain {
            if let instance = shared {
                return instance
            }
            // Acrobits 在未 initialize 时返回 nullptr 并断言;compat 放宽为惰性实例,
            // 引擎未初始化的行为由各子模块内部兜底(空集合/no-op + 日志)
            let instance = SoftphoneInstance()
            shared = instance
            return instance
        }
    }

    private static var shared: SoftphoneInstance?
}

// MARK: - SoftphoneInstance

@objcMembers public final class SoftphoneInstance: BridgeClass {
    private lazy var callsModule = SoftphoneInstanceCalls()
    private lazy var registrationModule = SoftphoneInstanceRegistration()
    private lazy var audioModule = SoftphoneInstanceAudio()
    private lazy var logModule = SoftphoneInstanceLog()
    private lazy var eventsModule = SoftphoneInstanceEvents()
    private lazy var notificationsModule = SoftphoneInstanceNotifications()
    private lazy var settingsModule = SoftphoneInstanceSettings()

    private var observerProxy: SoftphoneObserverProxyBridge?

    @objc public func setObserver(_ observer: SoftphoneObserverProxyBridge) {
        compatMain {
            observerProxy = observer
            // 引擎回调分发入口注册(CompatAdapter 持 weak,观察者生命周期由 App 管)
            CompatAdapter.shared.attach(observer: observer)
        }
        compatLog("setObserver")
    }

    @objc public func getObserver() -> SoftphoneObserverProxyBridge? {
        compatMain { observerProxy }
    }

    public func calls() -> SoftphoneInstanceCalls? { callsModule }
    public func registration() -> SoftphoneInstanceRegistration? { registrationModule }
    public func audio() -> SoftphoneInstanceAudio? { audioModule }
    public func log() -> SoftphoneInstanceLog? { logModule }
    public func events() -> SoftphoneInstanceEvents? { eventsModule }
    public func notifications() -> SoftphoneInstanceNotifications? { notificationsModule }
    public func settings() -> SoftphoneInstanceSettings? { settingsModule }
}

// MARK: - SoftphoneInstanceCalls

@objcMembers public final class SoftphoneInstanceCalls: BridgeClass {
    private lazy var conferencesModule = SoftphoneInstanceCallsConferences()

    public func conferences() -> SoftphoneInstanceCallsConferences? { conferencesModule }

    public func getActive() -> [SoftphoneCallEvent] {
        compatMain { CompatAdapter.shared.activeEvents() }
    }

    public func getState(_ call: SoftphoneCallEvent) -> CallStateType? {
        compatMain { CompatAdapter.shared.currentState(of: call) }
    }

    public func answerIncoming(call: SoftphoneCallEvent, media: CallDesiredMedia) -> Bool {
        compatMain { CompatAdapter.shared.answer(call) }
    }

    @discardableResult
    public func rejectIncomingHere(_ call: SoftphoneCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.reject(call) }
    }

    @discardableResult
    public func rejectIncomingEverywhere(_ call: SoftphoneCallEvent) -> Bool {
        // 单账户单腿:与 Here 等价
        compatMain { CompatAdapter.shared.reject(call) }
    }

    public func ignoreIncoming(_ call: SoftphoneCallEvent) -> Bool {
        compatLog("ignoreIncoming(App 未消费,引擎无对应动作,no-op)")
        return false
    }

    public func isAlive(_ call: SoftphoneCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.isAlive(call) }
    }

    public func setHeld(_ call: SoftphoneCallEvent, held: Bool) {
        compatMain { CompatAdapter.shared.setHeld(call, held: held) }
    }

    public func isHeld(_ call: SoftphoneCallEvent) -> CallHoldStates? {
        compatMain { CompatAdapter.shared.holdStates(of: call) }
    }

    public func close(_ call: SoftphoneCallEvent) {
        compatMain { CompatAdapter.shared.close(call) }
    }

    public func getStatistics(_ call: SoftphoneCallEvent) -> CallStatistics? {
        compatMain { CompatAdapter.shared.statistics(of: call) }
    }

    public func getMediaStatus(_ call: SoftphoneCallEvent) -> CallMediaStatus? {
        compatMain { CompatAdapter.shared.mediaStatus(of: call) }
    }

    public func getNetworkStatus(_ call: SoftphoneCallEvent) -> SoftphoneNetworkStatus? {
        compatMain { CompatAdapter.shared.networkStatus(of: call) }
    }

    public func findSipHeader(_ call: SoftphoneCallEvent, headerName: String) -> XmlTree? {
        compatMain { CompatAdapter.shared.findSipHeader(call, name: headerName) }
    }
}

// MARK: - SoftphoneInstanceCallsConferences(单腿组模型)

@objcMembers public final class SoftphoneInstanceCallsConferences: BridgeClass {
    public func list() -> [String] {
        compatMain { CompatAdapter.shared.groups() }
    }

    public func getCalls(conference: String) -> [SoftphoneCallEvent] {
        compatMain { CompatAdapter.shared.events(inGroup: conference) }
    }

    public func getCalls(call: SoftphoneCallEvent) -> [SoftphoneCallEvent] {
        compatMain {
            guard let group = CompatAdapter.shared.groupId(of: call) else { return [] }
            return CompatAdapter.shared.events(inGroup: group)
        }
    }

    public func get(_ call: SoftphoneCallEvent) -> String? {
        compatMain { CompatAdapter.shared.groupId(of: call) }
    }

    public func getSize(_ conference: String) -> Int {
        compatMain { CompatAdapter.shared.events(inGroup: conference).count }
    }

    public func getSize(call: SoftphoneCallEvent) -> Int {
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
    public func setActive(call: SoftphoneCallEvent) -> Bool {
        compatMain {
            guard let group = CompatAdapter.shared.groupId(of: call) else { return false }
            CompatAdapter.shared.setActiveGroup(group)
            return true
        }
    }

    @discardableResult
    public func move(call: SoftphoneCallEvent, conference: String) -> Bool {
        compatLog("no-op: move eventId=\(call.eventId) -> \(conference)(单腿组模型)")
        return false
    }

    @discardableResult
    public func move(call: SoftphoneCallEvent, target: SoftphoneCallEvent) -> Bool {
        compatLog("no-op: move(call:target:)(单腿组模型)")
        return false
    }

    public func split(call: SoftphoneCallEvent, activate: Bool) {
        compatLog("no-op: split eventId=\(call.eventId)(单腿组模型)")
    }

    public func transfer(call: SoftphoneCallEvent, target: SoftphoneCallEvent) {
        compatMain { CompatAdapter.shared.blindTransfer(from: call, to: target) }
    }

    @discardableResult
    public func attendedTransfer(call: SoftphoneCallEvent, target: SoftphoneCallEvent) -> Bool {
        compatMain { CompatAdapter.shared.attendedTransfer(source: call, target: target) }
    }
}

// MARK: - SoftphoneInstanceEvents

@objcMembers public final class SoftphoneInstanceEvents: BridgeClass {
    public func post(_ event: SoftphoneEvent) -> EventsPostResult {
        compatMain { CompatAdapter.shared.postOutgoing(event) }
    }
}

// MARK: - SoftphoneInstanceLog

@objcMembers public final class SoftphoneInstanceLog: BridgeClass {
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

// MARK: - SoftphoneInstanceRegistration

@objcMembers public final class SoftphoneInstanceRegistration: BridgeClass {
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

// MARK: - SoftphoneInstanceAudio

@objcMembers public final class SoftphoneInstanceAudio: BridgeClass {
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

// MARK: - SoftphoneInstanceSettings / Notifications / Push

@objcMembers public final class SoftphoneInstanceSettings: BridgeClass {
    private lazy var preferences = SoftphonePreferences()

    public func getPreferences() -> SoftphonePreferences? {
        preferences
    }
}

@objcMembers public final class SoftphoneInstanceNotifications: BridgeClass {
    private lazy var pushModule = SoftphoneInstanceNotificationPush()

    public func push() -> SoftphoneInstanceNotificationPush? {
        pushModule
    }
}

@objcMembers public final class SoftphoneInstanceNotificationPush: BridgeClass {
    public func setRegistrationId(token: Data?, usage: PushTokenUsage) {
        // Acrobits 语义:SDK 记录 token 并在变化时经 Push Token Reporter
        // 自动上报(App 账户 XML 的 pushTokenReporter* 节点提供模板;配置
        // 未就绪时挂起,saveAccount 补发)
        CompatPushReporter.shared.setToken(token, usage: usage)
    }

    @discardableResult
    public func handle(_ message: XmlTree, usage: PushTokenUsage,
                       completion: ((SoftphonePushNotificationCompletionInfo?) -> Void)?) -> ResourceHandle? {
        compatMain { CompatAdapter.shared.handlePush(message, usage: usage) }
        // App 侧 completion 传 nil 且线上实测不依赖(Acrobits 同行为);
        // 有传入则立即回执
        completion?(SoftphonePushNotificationCompletionInfo())
        return ResourceHandle()
    }
}
