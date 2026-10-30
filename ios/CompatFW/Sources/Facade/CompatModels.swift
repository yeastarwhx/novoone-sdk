//
//  CompatModels.swift
//  CompatFW
//
//  Acrobits 兼容层:回调参数类型与统计/保持/媒体模型、Preferences。
//

import Foundation

// MARK: - 通话统计(App 消费字段全集,§1.8)

@objcMembers public final class CallStatisticsTraffic: NSObject {
    public var bytesSent: Int64 = 0
    public var bytesReceived: Int64 = 0
}

@objcMembers public final class CallStatistics: NSObject {
    public var traffic: CallStatisticsTraffic?
    public var clockRateInHertz: Int = 0
    /// 时间戳单位(非毫秒),App 侧 jitterMs = maxJitter*1000/clockRate
    public var maxJitter: Double = 0
    public var avgJitter: Double = 0
    public var networkPacketLossPercentage: Int = 0
    public var jitterBufferPacketLossPercentage: Int = 0
    public var meteredNetworkJitter: Int64 = 0
    public var meteredAudioJitter: Int64 = 0
    public var lastRoundTripTimeInMilliseconds: Int = -1
    public var avgRoundTripTimeInMilliseconds: Int = -1
}

// MARK: - 媒体状态 / 保持状态 / 期望媒体

@objcMembers public final class CallMediaStatusStreamStatus: NSObject {
    public var outgoingPayloadFriendlyName: String?
    public var incomingPayloadFriendlyName: String?
}

@objcMembers public final class CallMediaStatus: NSObject {
    // 对齐 Acrobits:audio/video 均为 nullable(App 消费面 `?.audio?...`)
    public var audio: CallMediaStatusStreamStatus? = CallMediaStatusStreamStatus()
    public var video: CallMediaStatusStreamStatus?
    public var active = true
}

// MARK: - 网络状态(App:getNetworkStatus(call)?.networkInterfaceName,§1.1)

@objcMembers public final class SoftphoneNetworkStatus: BridgeClass {
    public let networkInterfaceName: String?

    public init(networkInterfaceName: String?) {
        self.networkInterfaceName = networkInterfaceName
        super.init()
    }
}

@objcMembers public final class CallHoldStates: NSObject {
    public var local: CallHoldStateType = .None
    public var remote: CallHoldStateType = .None

    public init(local: CallHoldStateType = .None, remote: CallHoldStateType = .None) {
        self.local = local
        self.remote = remote
    }
}

@objcMembers public final class CallDesiredMedia: NSObject {
    public var audioEnabled = true
    public var incomingVideoEnabled = false
    public var outgoingVideoEnabled = false

    public init(incomingVideoEnabled: Bool, outgoingVideoEnabled: Bool) {
        self.incomingVideoEnabled = incomingVideoEnabled
        self.outgoingVideoEnabled = outgoingVideoEnabled
        super.init()
    }

    public static func voiceOnly() -> CallDesiredMedia {
        CallDesiredMedia(incomingVideoEnabled: false, outgoingVideoEnabled: false)
    }

    public static func video() -> CallDesiredMedia {
        CallDesiredMedia(incomingVideoEnabled: true, outgoingVideoEnabled: true)
    }

    public func isAudioEnabled() -> Bool {
        audioEnabled
    }
}

@objcMembers public final class CallRejectReason: NSObject {
    public static func user() -> CallRejectReason { CallRejectReason() }
    public static func dnd() -> CallRejectReason { CallRejectReason() }
    public static func generic() -> CallRejectReason { CallRejectReason() }
}

// MARK: - 事件流变更 / 网络状态(回调参数,容器形态)

@objcMembers public final class SoftphoneChangedEvents: NSObject {}

@objcMembers public final class SoftphoneChangedStreams: NSObject {}

@objcMembers public final class SoftphoneNetworkConditionsRoundTrip: NSObject {
    public var averageRoundTripTimeInMilliseconds: Double = -1
}

@objcMembers public final class SoftphoneNetworkConditions: NSObject {
    public var roundTrip: SoftphoneNetworkConditionsRoundTrip = SoftphoneNetworkConditionsRoundTrip()
}

@objcMembers public final class NetworkInterfaceSnapshot: NSObject {
    public var network: NetworkType = .None
}

// MARK: - 余额 / 语音信箱 / 推送补全 / 订阅状态(协议完整性占位)

@objcMembers public final class BalanceRecord: NSObject {
    public var valid = false
    public var balance: Float = 0
    public var balanceString: String?
}

@objcMembers public final class VoicemailRecord: NSObject {
    public var isValid = false
    public var messagesWaiting = false
    public var oldMessages = 0
    public var newMessages = 0
}

@objcMembers public final class ResourceHandle: NSObject {}

@objcMembers public final class SoftphonePushNotificationCompletionInfo: NSObject {
    public var result: PushNotificationCompletionInfoResult = .NewData
}

/// 订阅状态包装(Acrobits NS_SWIFT_UNAVAILABLE 构造,compat 仅作回调参数容器)
@objcMembers public final class SoftphoneSubscriptionStateType: NSObject {
    public let stateValue: SubscriptionStateTypeEnum

    public init(_ value: SubscriptionStateTypeEnum) {
        self.stateValue = value
    }

    public func isNotSubscribed() -> Bool { stateValue == .NotSubscribed }
    public func isSubscribing() -> Bool { stateValue == .Subscribing }
    public func isSubscribed() -> Bool { stateValue == .Subscribed }
    public func isRefreshing() -> Bool { stateValue == .Refreshing }
    public func isTerminated() -> Bool { stateValue == .Terminated }
    public func isError() -> Bool { stateValue == .Error }
}

@objcMembers public final class SoftphoneMessagingComposingInfo: NSObject {}

// MARK: - SoftphonePreferences(App 消费属性子集)

@objcMembers public final class SoftphonePreferences: NSObject {
    public var trafficLogging = false
    public var echoSuppressionEnabled = false
    public var volumeBoostMicrophone: Int32 = 0
    public var volumeBoostPlayback: Int32 = 0
    public var userAgentOverride: String?
    public var useCallKit = true

    /// 系统通话记录同步（App 默认关闭语义：冷启动 UserDefaults 覆盖）。
    /// 赋值即时下发引擎：无活跃通话时重建 CallKit provider 生效，有则
    /// 挂起至下一通电话前
    public var includesCallKitCallsInRecent = true {
        didSet { SipWebrtcEngine.shared().setCallsInRecentsEnabled(includesCallKitCallsInRecent) }
    }
}
