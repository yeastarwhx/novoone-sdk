//
//  CompatDelegate.swift
//  CompatFW
//
//  Acrobits 兼容层:Serializer 日志出口 + SoftphoneDelegateBridge 回调协议
//  (29 方法,SOFTPHONE_MULTIPLE_ACCOUNTS=on 形态)+ 观察者代理。
//

import Foundation

// MARK: - Serializer

@objc public protocol Serializer: NSObjectProtocol {
    @objc(write:) func write(_ data: Data) -> Int
    @objc func availToWrite() -> Int
}

@objcMembers public final class NSLogSerializer: NSObject, Serializer {
    private let prefix: String

    public init?(prefix: String?) {
        self.prefix = prefix ?? ""
        super.init()
    }

    public func write(_ data: Data) -> Int {
        if let text = String(data: data, encoding: .utf8) {
            NSLog("%@%@", prefix, text)
        }
        return Int(data.count)
    }

    public func availToWrite() -> Int {
        Int.max
    }
}

// MARK: - SoftphoneDelegateBridge(全部可选回调;必选项 compat 以默认实现兜底)

@objc public protocol SoftphoneDelegateBridge: NSObjectProtocol {
    @objc optional func onRegistrationStateChanged(state: RegistratorStateType, accountId: String)
    @objc optional func onNetworkChangeDetected(_ network: NetworkType)
    @objc optional func onNewEvent(_ event: SoftphoneEvent)
    @objc optional func onCallStateChanged(state: CallStateType, call: SoftphoneCallEvent)
    @objc optional func onHoldStateChanged(states: CallHoldStates, call: SoftphoneCallEvent)
    @objc optional func onMediaStatusChanged(media: CallMediaStatus, call: SoftphoneCallEvent)
    @objc optional func onEventsChanged(events: SoftphoneChangedEvents, streams: SoftphoneChangedStreams)
    @objc optional func onRegistrationErrorMessage(message: String, accountId: String)
    @objc optional func onDialogEvent(accountId: String)
    @objc optional func onSubscriptionStateChanged(accountId: String, subscriptionId: String,
                                                   state: SoftphoneSubscriptionStateType)
    @objc optional func onSubscriptionNotify(accountId: String, subscriptionId: String,
                                             contentType: String, body: String)
    @objc optional func onPushTestScheduled(accountId: String, result: Int)
    @objc optional func onPushTestArrived(accountId: String)
    @objc optional func onMissedCalls(_ callEvents: [SoftphoneCallEvent])
    @objc optional func onVoicemail(voicemail: VoicemailRecord, accountId: String)
    @objc optional func onBalance(balance: BalanceRecord, accountId: String)
    @objc optional func onAudioRouteChanged(_ route: AudioRouteType)
    @objc optional func softphoneSimulatedMicrophoneStopped()
    @objc optional func onCallRepositoryChanged()
    @objc optional func onComposingInfo(_ info: SoftphoneMessagingComposingInfo)
    @objc optional func getRingtonePath(_ call: SoftphoneCallEvent) -> String!
    @objc optional func onTransferOffered(_ call: SoftphoneCallEvent)
    @objc optional func onTransferResult(call: SoftphoneCallEvent, success: Bool)
    @objc optional func onContactsChanged(_ source: String)
    @objc optional func onContactSourceStateChanged(_ source: String)
    @objc optional func onSettingsChanged()
    @objc optional func onNetworkCertificateVerificationFailed(host: String, certificateHash: String)
    @objc optional func onNetworkConditions(_ networkConditions: SoftphoneNetworkConditions)
    @objc optional func overrideNetworkPriorities(_ network: NetworkInterfaceSnapshot)
    @objc optional func onMuteChanged(muted: Bool, type: MicrophoneType)
    @objc optional func onSimulatedMicrophoneStopped()
}

// MARK: - SoftphoneObserverProxyBridge

@objcMembers public final class SoftphoneObserverProxyBridge: BridgeClass {
    public weak var delegate: (SoftphoneDelegateBridge)?
}
