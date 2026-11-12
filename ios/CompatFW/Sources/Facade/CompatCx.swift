//
//  CompatCx.swift
//  CompatFW
//
//  Acrobits 兼容层:NovoSDK_Cx(CallKit 门面)与
//  CallRedirectionManager(咨询转/盲转状态机)。
//
//  转接状态机语义(与 Acrobits 的有意差异):perform* 发起后即置终态——
//  Succeeded 表示"桥接动作已成功发出",不跟踪 REFER/NOTIFY 异步进度
//  (Acrobits 为 NOTIFY 驱动的 InProgress → 终态状态机)。四张
//  delegate 表当前无派发点:注册/注销接口保留 Acrobits API 形状,
//  事件不会送达;若后续需 NOTIFY 驱动的状态流,接线点为引擎侧
//  ys_call_transfer_state 回调。
//
//  形状面口径:NovoSDK_Cx 的 processIntent/reportCall/
//  updateCallKitConfiguration 等入口为对齐 Acrobits API 形状保留,
//  当前 App 未消费(引擎 coordinator 内置等价实现或系统行为覆盖),
//  不按死代码清除。
//

import Foundation
import CallKit
import Intents

// MARK: - NovoSDK_Cx / NovoSDK_Cx_Delegate

@objc public protocol NovoSDK_Cx_Delegate: NSObjectProtocol {
    @objc optional func cxCallUpdate(_ callUpdate: CXCallUpdate, forCall call: NovoSDKCallEvent)
    @objc optional func cxProviderConfiguration(_ configuration: CXProviderConfiguration) -> CXProviderConfiguration?
}

@objcMembers public final class NovoSDK_Cx: BridgeClass {
    // 持有对齐 Acrobits API 面;cxCallUpdate 定制不透传——引擎 coordinator
    // 已内置等价实现(分机 generic handle/supportsGrouping=false 等,注释对齐线上)
    public weak var delegate: (NovoSDK_Cx_Delegate)?

    private static let sharedInstance = NovoSDK_Cx()

    @objc public static func instance() -> NovoSDK_Cx {
        sharedInstance
    }

    @discardableResult
    @objc public func setCallKitIcon(_ imageName: String) -> Bool {
        // CXProviderConfiguration.icon 自 iOS 14 起移除(引擎 coordinator 注释:
        // 系统卡片回落 App 图标)——无接线点,记录后返回成功
        NSLog("[compat] setCallKitIcon %@(iOS 14+ 系统回落 App 图标)", imageName)
        return true
    }

    @objc public func isCallKitAvailable() -> Bool {
        true
    }

    @objc public func callKitConfiguration() -> CXProviderConfiguration {
        CXProviderConfiguration(localizedName: "NovoOne")
    }

    @objc public func updateCallKitConfiguration(_ configuration: CXProviderConfiguration) {
        NSLog("[compat] updateCallKitConfiguration")
    }

    @objc public func processIntent(_ intent: INIntent) -> Bool {
        false
    }

    @objc public func reportCall(_ call: NovoSDKCallEvent, updated update: CXCallUpdate) {
        NSLog("[compat] reportCall eventId=\(call.eventId)")
    }

    @objc public func callKitConfigureAudioSession() {
        // 引擎 coordinator 是 CXProviderDelegate 自驱音频线(useManualAudio
        // 模式唯一驱动源)——compat 转发会双触发,不接(App 未调用这些入口)
        NSLog("[compat] callKitConfigureAudioSession(引擎 coordinator 自驱,不转发)")
    }

    @objc public func callKitAudioSessionDidActivate() {
        NSLog("[compat] callKitAudioSessionDidActivate(引擎 coordinator 自驱,不转发)")
    }

    @objc public func callKitAudioSessionDidDeactivate() {
        NSLog("[compat] callKitAudioSessionDidDeactivate(引擎 coordinator 自驱,不转发)")
    }

    @objc public func callKitSetSomeCallActive(_ active: Bool) {
        NSLog("[compat] callKitSetSomeCallActive \(active)")
    }

    @objc public func setSilentSoundInForeground(_ set: Bool) {}

    @objc public func isSilentSoundInForegroundSet() -> Bool {
        false
    }

    @objc public func resetCallKitProvider() {
        NSLog("[compat] resetCallKitProvider")
    }
}

// MARK: - CallRedirectionManager(转接状态机)

@objc public enum CallRedirectTypeEnum: UInt {
    case None = 0
    case Forward
    case BlindTransfer
    case AttendedTransfer
}

@objcMembers public final class CallRedirectType: NSObject {
    public let raw: CallRedirectTypeEnum
    public init(_ value: CallRedirectTypeEnum) {
        raw = value
    }
    public func isNone() -> Bool { raw == .None }
    public func isForward() -> Bool { raw == .Forward }
    public func isBlindTransfer() -> Bool { raw == .BlindTransfer }
    public func isAttendedTransfer() -> Bool { raw == .AttendedTransfer }
    public func isTransferType() -> Bool { raw == .BlindTransfer || raw == .AttendedTransfer }
}

@objc public enum CallRedirectStateEnum: UInt {
    case Inactive = 0
    case SourceAssigned
    case TargetAssigned
    case InProgress
    case Succeeded
    case Failed
    case Cancelled
}

@objcMembers public final class CallRedirectState: NSObject {
    public let raw: CallRedirectStateEnum
    public init(_ value: CallRedirectStateEnum) {
        raw = value
    }
    public func isInactive() -> Bool { raw == .Inactive }
    public func isSourceAssigned() -> Bool { raw == .SourceAssigned }
    public func isTargetAssigned() -> Bool { raw == .TargetAssigned }
    public func isInProgress() -> Bool { raw == .InProgress }
    public func isSucceeded() -> Bool { raw == .Succeeded }
    public func isFailed() -> Bool { raw == .Failed }
    public func isCancelled() -> Bool { raw == .Cancelled }
    public func isTerminal() -> Bool { isSucceeded() || isFailed() || isCancelled() }
}

@objc public enum AttendedTransferCapabilityEnum: UInt {
    case NotAvailable = 0
    case Direct
    case PickAnotherCall
    case NewCall
}

@objcMembers public final class AttendedTransferCapability: NSObject {
    public let raw: AttendedTransferCapabilityEnum
    public init(_ value: AttendedTransferCapabilityEnum) {
        raw = value
    }
    public func isNotAvailable() -> Bool { raw == .NotAvailable }
    public func isDirect() -> Bool { raw == .Direct }
    public func isPickAnotherCall() -> Bool { raw == .PickAnotherCall }
    public func isNewCall() -> Bool { raw == .NewCall }
}

@objcMembers public final class SourceChangeData: NSObject {
    public internal(set) var type: CallRedirectType?
    public internal(set) var newSource: NovoSDKCallEvent?
}

@objcMembers public final class TargetChangeData: NSObject {
    public internal(set) var type: CallRedirectType?
    public internal(set) var source: NovoSDKCallEvent?
    public internal(set) var newTarget: NovoSDKCallEvent?
}

@objcMembers public final class StateChangeData: NSObject {
    public internal(set) var type: CallRedirectType?
    public internal(set) var source: NovoSDKCallEvent?
    public internal(set) var newState: CallRedirectState?
}

@objcMembers public final class SuccessfulRedirectData: NSObject {
    public internal(set) var timestamp: Double = 0
    public internal(set) var call: NovoSDKCallEvent?
    public internal(set) var sourceUri: String?
    public internal(set) var targetUri: String?
    public internal(set) var targetCallId: String?
}

@objcMembers public final class CallRedirectCapabilities: NSObject {
    public internal(set) var attendedTransferCapability: AttendedTransferCapability?
    public internal(set) var attendedTransferTargets: [NovoSDKCallEvent] = []

    public func canForward() -> Bool { false }
    public func canBlindTransfer() -> Bool { true }
    public func canAttendedTransfer() -> Bool { attendedTransferTargets.count > 0 }
}

@objc public protocol CallRedirectionStateChangeDelegate: NSObjectProtocol {
    @objc(redirectStateChanged:) func redirectStateChanged(data: StateChangeData)
}

@objc public protocol CallRedirectionSourceChangeDelegate: NSObjectProtocol {
    @objc(redirectSourceChanged:) func redirectSourceChanged(data: SourceChangeData)
}

@objc public protocol CallRedirectionTargetChangeDelegate: NSObjectProtocol {
    @objc(redirectTargetChanged:) func redirectTargetChanged(data: TargetChangeData)
}

@objc public protocol CallRedirectionSuccessfulRedirectDelegate: NSObjectProtocol {
    @objc(onSuccessfulRedirect:) func onSuccessfulRedirect(data: SuccessfulRedirectData)
}

@objcMembers public final class CallRedirectionManager: NSObject {
    private override init() {
        super.init()
    }

    private static let sharedInstance = CallRedirectionManager()

    @objc public static func instance() -> CallRedirectionManager {
        sharedInstance
    }

    public internal(set) var state: CallRedirectState?
    public internal(set) var currentRedirectFlow: CallRedirectType?
    public internal(set) var redirectSource: NovoSDKCallEvent?
    public internal(set) var redirectTarget: NovoSDKCallEvent?

    private var stateDelegates = NSHashTable<NSObject>.weakObjects()
    private var sourceDelegates = NSHashTable<NSObject>.weakObjects()
    private var targetDelegates = NSHashTable<NSObject>.weakObjects()
    private var successfulDelegates = NSHashTable<NSObject>.weakObjects()

    public func addStateChangeDelegate(_ delegate: CallRedirectionStateChangeDelegate) {
        if let object = delegate as? NSObject { stateDelegates.add(object) }
    }

    public func addSourceChangeDelegate(_ delegate: CallRedirectionSourceChangeDelegate) {
        if let object = delegate as? NSObject { sourceDelegates.add(object) }
    }

    public func addTargetChangeDelegate(_ delegate: CallRedirectionTargetChangeDelegate) {
        if let object = delegate as? NSObject { targetDelegates.add(object) }
    }

    public func addSuccessfulRedirectDelegate(_ delegate: CallRedirectionSuccessfulRedirectDelegate) {
        if let object = delegate as? NSObject { successfulDelegates.add(object) }
    }

    public func removeStateChangeDelegate(_ delegate: CallRedirectionStateChangeDelegate) {
        if let object = delegate as? NSObject { stateDelegates.remove(object) }
    }

    public func removeSourceChangeDelegate(_ delegate: CallRedirectionSourceChangeDelegate) {
        if let object = delegate as? NSObject { sourceDelegates.remove(object) }
    }

    public func removeTargetChangeDelegate(_ delegate: CallRedirectionTargetChangeDelegate) {
        if let object = delegate as? NSObject { targetDelegates.remove(object) }
    }

    public func removeSuccessfulRedirectDelegate(_ delegate: CallRedirectionSuccessfulRedirectDelegate) {
        if let object = delegate as? NSObject { successfulDelegates.remove(object) }
    }

    public func getRedirectCapabilities(_ callEvent: NovoSDKCallEvent) -> CallRedirectCapabilities? {
        let targets = CompatAdapter.shared.redirectTargets(excluding: callEvent)
        let capabilities = CallRedirectCapabilities()
        if targets.isEmpty {
            capabilities.attendedTransferCapability = AttendedTransferCapability(.NotAvailable)
        } else {
            capabilities.attendedTransferCapability = AttendedTransferCapability(.PickAnotherCall)
            capabilities.attendedTransferTargets = targets
        }
        return capabilities
    }

    public func canInitiateRedirect() -> Bool {
        false
    }

    public func cancelRedirect() {
        NSLog("[compat] cancelRedirect")
        redirectSource = nil
        redirectTarget = nil
        currentRedirectFlow = nil
        state = CallRedirectState(.Inactive)
    }

    public func setBlindTransferSource(_ callEvent: NovoSDKCallEvent) {
        redirectSource = callEvent
        currentRedirectFlow = CallRedirectType(.BlindTransfer)
        state = CallRedirectState(.SourceAssigned)
    }

    public func setForwardingSource(_ callEvent: NovoSDKCallEvent) {
        redirectSource = callEvent
        currentRedirectFlow = CallRedirectType(.Forward)
        state = CallRedirectState(.SourceAssigned)
    }

    public func setAttendedTransferSource(_ callEvent: NovoSDKCallEvent) {
        redirectSource = callEvent
        currentRedirectFlow = CallRedirectType(.AttendedTransfer)
        state = CallRedirectState(.SourceAssigned)
    }

    public func setAttendedTransferTarget(_ callEvent: NovoSDKCallEvent) {
        redirectTarget = callEvent
        state = CallRedirectState(.TargetAssigned)
    }

    public func isBlindTransferSource(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectSource === callEvent && currentRedirectFlow?.isBlindTransfer() == true
    }

    public func isBlindTransferTarget(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectTarget === callEvent && currentRedirectFlow?.isBlindTransfer() == true
    }

    public func isForwardingSource(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectSource === callEvent && currentRedirectFlow?.isForward() == true
    }

    public func isRedirectParticipant(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectSource === callEvent || redirectTarget === callEvent
    }

    public func isAttendedTransferSource(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectSource === callEvent && currentRedirectFlow?.isAttendedTransfer() == true
    }

    public func isAttendedTransferTarget(_ callEvent: NovoSDKCallEvent) -> Bool {
        redirectTarget === callEvent && currentRedirectFlow?.isAttendedTransfer() == true
    }

    public func performBlindTransferToTarget(_ callToBeTransferredTo: NovoSDKCallEvent) {
        guard let source = redirectSource else { return }
        CompatAdapter.shared.blindTransfer(from: source, to: callToBeTransferredTo)
        /* REFER 已发出即置 Succeeded(发起成功语义,非转接终态)——
         * NOTIFY 进度不回流,见文件头状态机语义声明 */
        state = CallRedirectState(.Succeeded)
    }

    public func performForwardToTarget(_ callToBeTransferredTo: NovoSDKCallEvent) {
        NSLog("[compat] performForwardToTarget(引擎无 Forward 动作,暂不支持)")
    }

    public func performAttendedTransfer() {
        guard let source = redirectSource, let target = redirectTarget else { return }
        /* 返回值 = 两腿桥接动作是否发起成功(挂断+REFER 发出),非转接终态,
         * 见文件头状态机语义声明 */
        if CompatAdapter.shared.attendedTransfer(source: source, target: target) {
            state = CallRedirectState(.Succeeded)
        } else {
            state = CallRedirectState(.Failed)
        }
    }

    public func performAttendedTransferBetween(source: NovoSDKCallEvent, target: NovoSDKCallEvent) {
        if CompatAdapter.shared.attendedTransfer(source: source, target: target) {
            state = CallRedirectState(.Succeeded)
        } else {
            state = CallRedirectState(.Failed)
        }
    }
}
