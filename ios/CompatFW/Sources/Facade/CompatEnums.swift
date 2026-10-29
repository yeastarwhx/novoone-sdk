//
//  CompatEnums.swift
//  CompatFW
//
//  Acrobits 兼容层:枚举 + ObjC 导入名全局常量 + toString 静态类。
//  枚举成员与原始值逐字对齐 SoftphoneBridge.h(25.3.37)。
//

import Foundation

// MARK: - CallStateType(17 值,顺序=Acrobits 头文件声明序)

@objc public enum CallStateType: UInt {
    case Unknown = 0
    case Trying
    case Ringing
    case Busy
    case IncomingAnswered
    case IncomingTrying
    case IncomingRinging
    case IncomingIgnored
    case IncomingRejected
    case IncomingMissed
    case Established
    case Error
    case Unauthorized
    case Terminated
    case IncomingForwarded
    case IncomingAnsweredElsewhere
    case RedirectedToAlternativeService
}

public let CallState_Unknown = CallStateType.Unknown
public let CallState_Trying = CallStateType.Trying
public let CallState_Ringing = CallStateType.Ringing
public let CallState_Busy = CallStateType.Busy
public let CallState_IncomingAnswered = CallStateType.IncomingAnswered
public let CallState_IncomingTrying = CallStateType.IncomingTrying
public let CallState_IncomingRinging = CallStateType.IncomingRinging
public let CallState_IncomingIgnored = CallStateType.IncomingIgnored
public let CallState_IncomingRejected = CallStateType.IncomingRejected
public let CallState_IncomingMissed = CallStateType.IncomingMissed
public let CallState_Established = CallStateType.Established
public let CallState_Error = CallStateType.Error
public let CallState_Unauthorized = CallStateType.Unauthorized
public let CallState_Terminated = CallStateType.Terminated
public let CallState_IncomingForwarded = CallStateType.IncomingForwarded
public let CallState_IncomingAnsweredElsewhere = CallStateType.IncomingAnsweredElsewhere
public let CallState_RedirectedToAlternativeService = CallStateType.RedirectedToAlternativeService

// MARK: - RegistratorStateType(9 值)

@objc public enum RegistratorStateType: UInt {
    case None = 0
    case Discovering
    case NotRegistered
    case PushHandshake
    case Registering
    case Registered
    case Unregistering
    case Unauthorized
    case Error
}

public let RegistratorState_None = RegistratorStateType.None
public let RegistratorState_Discovering = RegistratorStateType.Discovering
public let RegistratorState_NotRegistered = RegistratorStateType.NotRegistered
public let RegistratorState_PushHandshake = RegistratorStateType.PushHandshake
public let RegistratorState_Registering = RegistratorStateType.Registering
public let RegistratorState_Registered = RegistratorStateType.Registered
public let RegistratorState_Unregistering = RegistratorStateType.Unregistering
public let RegistratorState_Unauthorized = RegistratorStateType.Unauthorized
public let RegistratorState_Error = RegistratorStateType.Error

// MARK: - CallHoldStateType(4 值)

@objc public enum CallHoldStateType: UInt {
    case None = 0
    case Active
    case Pending
    case Held
}

public let CallHoldState_None = CallHoldStateType.None
public let CallHoldState_Active = CallHoldStateType.Active
public let CallHoldState_Pending = CallHoldStateType.Pending
public let CallHoldState_Held = CallHoldStateType.Held

// MARK: - AudioRouteType(6 值)

@objc public enum AudioRouteType: UInt {
    case Unselected = 0
    case Receiver = 1
    case Speaker = 2
    case BluetoothSCO = 3
    case BluetoothA2DP = 4
    case Headset = 5
}

public let AudioRoute_Unselected = AudioRouteType.Unselected
public let AudioRoute_Receiver = AudioRouteType.Receiver
public let AudioRoute_Speaker = AudioRouteType.Speaker
public let AudioRoute_BluetoothSCO = AudioRouteType.BluetoothSCO
public let AudioRoute_BluetoothA2DP = AudioRouteType.BluetoothA2DP
public let AudioRoute_Headset = AudioRouteType.Headset

// MARK: - PushTokenUsage

@objc public enum PushTokenUsage: UInt {
    case IncomingCall = 0
    case Other = 1
    case All = 0xFFFF
}

public let PushTokenUsage_IncomingCall = PushTokenUsage.IncomingCall
public let PushTokenUsage_Other = PushTokenUsage.Other
public let PushTokenUsage_All = PushTokenUsage.All

// MARK: - EventsPostResult(全局常量名带 PostResult_ 前缀)

@objc public enum EventsPostResult: UInt {
    case Success = 0
    case NoNetwork = 1
    case WrongStream = 1000
    case NoAccount = 1001
    case NoRecipient = 1002
    case TooManyRecipients = 1003
    case NoStream = 1004
    case UnsupportedByAccount = 1005
    case ProcessingFailed = 1100
    case AccountOverride = 1500
    case UsedEvent = 2000
    case UnpostableType = 2001
    case UnsupportedFeature = 2002
    case InvalidStream = 2003
    case InvalidRecipient = 2004
}

public let PostResult_Success = EventsPostResult.Success
public let PostResult_NoNetwork = EventsPostResult.NoNetwork
public let PostResult_WrongStream = EventsPostResult.WrongStream
public let PostResult_NoAccount = EventsPostResult.NoAccount
public let PostResult_NoRecipient = EventsPostResult.NoRecipient
public let PostResult_TooManyRecipients = EventsPostResult.TooManyRecipients
public let PostResult_NoStream = EventsPostResult.NoStream
public let PostResult_UnsupportedByAccount = EventsPostResult.UnsupportedByAccount
public let PostResult_ProcessingFailed = EventsPostResult.ProcessingFailed
public let PostResult_AccountOverride = EventsPostResult.AccountOverride
public let PostResult_UsedEvent = EventsPostResult.UsedEvent
public let PostResult_UnpostableType = EventsPostResult.UnpostableType
public let PostResult_UnsupportedFeature = EventsPostResult.UnsupportedFeature
public let PostResult_InvalidStream = EventsPostResult.InvalidStream
public let PostResult_InvalidRecipient = EventsPostResult.InvalidRecipient

// MARK: - NetworkType / MicrophoneType / EventDirectionType / CallResultType

@objc public enum NetworkType: UInt {
    case None = 0
    case Cellular
    case Wifi
}

public let NetworkType_None = NetworkType.None
public let NetworkType_Cellular = NetworkType.Cellular
public let NetworkType_Wifi = NetworkType.Wifi

@objc public enum MicrophoneType: UInt {
    case Unknown = 0
    case Physical
    case Simulated
}

public let MicrophoneType_Unknown = MicrophoneType.Unknown
public let MicrophoneType_Physical = MicrophoneType.Physical
public let MicrophoneType_Simulated = MicrophoneType.Simulated

@objc public enum EventDirectionType: UInt {
    case Unspecified = 0
    case Incoming
    case Outgoing
}

public let EventDirectionType_Unspecified = EventDirectionType.Unspecified
public let EventDirectionType_Incoming = EventDirectionType.Incoming
public let EventDirectionType_Outgoing = EventDirectionType.Outgoing

@objc public enum CallResultType: UInt {
    case Unknown = 0
    case Accepted = 1
    case Missed = 2
    case Rejected = 4
    case Busy = 8
    case Answered = 16
    case Unanswered = 32
    case Canceled = 64
    case Error = 128
    case Forwarded = 256
    case Initiated = 512
    case AnsweredElsewhere = 1024
    case Transferred = 2048
}

public let CallResultType_Unknown = CallResultType.Unknown
public let CallResultType_Accepted = CallResultType.Accepted
public let CallResultType_Missed = CallResultType.Missed
public let CallResultType_Rejected = CallResultType.Rejected
public let CallResultType_Busy = CallResultType.Busy
public let CallResultType_Answered = CallResultType.Answered
public let CallResultType_Unanswered = CallResultType.Unanswered
public let CallResultType_Canceled = CallResultType.Canceled
public let CallResultType_Error = CallResultType.Error
public let CallResultType_Forwarded = CallResultType.Forwarded
public let CallResultType_Initiated = CallResultType.Initiated
public let CallResultType_AnsweredElsewhere = CallResultType.AnsweredElsewhere
public let CallResultType_Transferred = CallResultType.Transferred

// MARK: - PushNotificationCompletionInfoResult / SubscriptionStateTypeEnum

@objc public enum PushNotificationCompletionInfoResult: UInt {
    case Failed = 0
    case NoData
    case NewData
}

public let PushNotificationCompletionInfoResult_Failed = PushNotificationCompletionInfoResult.Failed
public let PushNotificationCompletionInfoResult_NoData = PushNotificationCompletionInfoResult.NoData
public let PushNotificationCompletionInfoResult_NewData = PushNotificationCompletionInfoResult.NewData

@objc public enum SubscriptionStateTypeEnum: UInt {
    case NotSubscribed = 0
    case Subscribing
    case Subscribed
    case Refreshing
    case Terminated
    case Error
}

// MARK: - toString 静态类(对齐 Acrobits)

@objc public final class CallState: NSObject {
    @objc public static func isTerminal(_ state: CallStateType) -> Bool {
        switch state {
        case .IncomingRejected, .IncomingMissed, .IncomingForwarded, .IncomingAnsweredElsewhere,
             .Terminated, .Error, .RedirectedToAlternativeService, .Unauthorized, .Busy:
            return true
        default:
            return false
        }
    }

    @objc public static func isFailed(_ state: CallStateType) -> Bool {
        switch state {
        case .IncomingMissed, .IncomingRejected, .IncomingForwarded, .IncomingAnsweredElsewhere,
             .Error, .Terminated, .RedirectedToAlternativeService:
            return true
        default:
            return false
        }
    }

    @objc public static func toString(_ state: CallStateType) -> String {
        switch state {
        case .Unknown: return "Unknown"
        case .Trying: return "Trying"
        case .Ringing: return "Ringing"
        case .Busy: return "Busy"
        case .IncomingAnswered: return "IncomingAnswered"
        case .IncomingTrying: return "IncomingTrying"
        case .IncomingRinging: return "IncomingRinging"
        case .IncomingIgnored: return "IncomingIgnored"
        case .IncomingRejected: return "IncomingRejected"
        case .IncomingMissed: return "IncomingMissed"
        case .Established: return "Established"
        case .Error: return "Error"
        case .Unauthorized: return "Unauthorized"
        case .Terminated: return "Terminated"
        case .IncomingForwarded: return "IncomingForwarded"
        case .IncomingAnsweredElsewhere: return "IncomingAnsweredElsewhere"
        case .RedirectedToAlternativeService: return "RedirectedToAlternativeService"
        }
    }
}

@objc public final class AudioRoute: NSObject {
    @objc public static func toString(_ type: AudioRouteType) -> String {
        switch type {
        case .Unselected: return "Unselected"
        case .Receiver: return "Receiver"
        case .Speaker: return "Speaker"
        case .BluetoothSCO: return "BluetoothSCO"
        case .BluetoothA2DP: return "BluetoothA2DP"
        case .Headset: return "Headset"
        }
    }
}

@objc public final class RegistratorState: NSObject {
    @objc public static func toString(_ state: RegistratorStateType) -> String {
        switch state {
        case .None: return "None"
        case .Discovering: return "Discovering"
        case .NotRegistered: return "NotRegistered"
        case .PushHandshake: return "PushHandshake"
        case .Registering: return "Registering"
        case .Registered: return "Registered"
        case .Unregistering: return "Unregistering"
        case .Unauthorized: return "Unauthorized"
        case .Error: return "Error"
        }
    }
}

@objc public final class CallResult: NSObject {
    @objc public static func toString(_ state: CallResultType) -> String {
        switch state {
        case .Unknown: return "Unknown"
        case .Accepted: return "Accepted"
        case .Missed: return "Missed"
        case .Rejected: return "Rejected"
        case .Busy: return "Busy"
        case .Answered: return "Answered"
        case .Unanswered: return "Unanswered"
        case .Canceled: return "Canceled"
        case .Error: return "Error"
        case .Forwarded: return "Forwarded"
        case .Initiated: return "Initiated"
        case .AnsweredElsewhere: return "AnsweredElsewhere"
        case .Transferred: return "Transferred"
        }
    }
}

@objc public final class EventDirection: NSObject {
    @objc public static func toString(_ direction: EventDirectionType) -> String {
        switch direction {
        case .Unspecified: return "Unspecified"
        case .Incoming: return "Incoming"
        case .Outgoing: return "Outgoing"
        }
    }
}
