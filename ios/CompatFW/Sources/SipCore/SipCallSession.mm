#import "SipCallSession.h"

NSString * const SipCallStateTrying           = @"Trying";
NSString * const SipCallStateRinging          = @"Ringing";
NSString * const SipCallStateEstablished      = @"Established";
NSString * const SipCallStateTerminated       = @"Terminated";
NSString * const SipCallStateBusy             = @"Busy";
NSString * const SipCallStateError            = @"Error";
NSString * const SipCallStateUnauthorized     = @"Unauthorized";
NSString * const SipCallStateIncomingTrying   = @"IncomingTrying";
NSString * const SipCallStateIncomingRinging  = @"IncomingRinging";
NSString * const SipCallStateIncomingAnswered = @"IncomingAnswered";
NSString * const SipCallStateIncomingRejected = @"IncomingRejected";
NSString * const SipCallStateIncomingMissed   = @"IncomingMissed";

/* 呼出 groupId 前缀：与来电 String(callId) 数字串域隔离，避免撞号 */
NSString * const SipGroupIdOutgoingPrefix     = @"o";

NSString * const SipSessionKeySessionId       = @"sessionId";
NSString * const SipSessionKeyCallId          = @"callId";
NSString * const SipSessionKeyGroupId         = @"groupId";
NSString * const SipSessionKeyDirection       = @"direction";
NSString * const SipSessionKeyIsIncoming      = @"isIncoming";
NSString * const SipSessionKeyRemoteNumber    = @"remoteNumber";
NSString * const SipSessionKeyAccountName     = @"accountName";
NSString * const SipSessionKeyRequestId       = @"requestId";
NSString * const SipSessionKeyCallerIdName    = @"callerIdName";
NSString * const SipSessionKeyCallStateView   = @"callStateView";
NSString * const SipSessionKeyIsTerminal      = @"isTerminal";
NSString * const SipSessionKeyPjsuaState      = @"pjsuaState";
NSString * const SipSessionKeyLastStatus      = @"lastStatus";
NSString * const SipSessionKeyHoldFlag        = @"holdFlag";
NSString * const SipSessionKeyRemoteHoldFlag  = @"remoteHoldFlag";
NSString * const SipSessionKeyMuteFlag        = @"muteFlag";
NSString * const SipSessionKeyAnswerRequested = @"answerRequested";
NSString * const SipSessionKeyCanBeAnswered   = @"canBeAnswered";
NSString * const SipSessionKeyIsOnHold        = @"isOnHold";
NSString * const SipSessionKeyCreatedAt       = @"createdAt";
NSString * const SipSessionKeyCallStartTime   = @"callStartTime";
NSString * const SipSessionKeyHoldStartTime   = @"holdStartTime";
NSString * const SipSessionKeyCallKitUuid     = @"callKitUuid";

long long SipCurrentTimeMillis(void)
{
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

@implementation SipCallSession

- (instancetype)initWithSessionId:(long long)sessionId direction:(SipCallDirection)direction
{
    self = [super init];
    if (self) {
        _sessionId = sessionId;
        _direction = direction;
        _callId = -1;
        _callStateView = SipCallStateTrying;
    }
    return self;
}

#pragma mark - 判定（契约字段，对齐安卓 CallSession）

- (BOOL)isTerminal
{
    return [self.callStateView isEqualToString:SipCallStateTerminated]
        || [self.callStateView isEqualToString:SipCallStateBusy]
        || [self.callStateView isEqualToString:SipCallStateError]
        || [self.callStateView isEqualToString:SipCallStateUnauthorized]
        || [self.callStateView isEqualToString:SipCallStateIncomingRejected]
        || [self.callStateView isEqualToString:SipCallStateIncomingMissed];
}

- (BOOL)isIncoming
{
    return self.direction == SipCallDirectionIn;
}

- (BOOL)canBeAnswered
{
    return self.isIncoming
        && [self.callStateView isEqualToString:SipCallStateIncomingRinging]
        && !self.answerRequested
        && self.offerSdp.length > 0;
}

- (BOOL)isOnHold
{
    return self.holdFlag || self.remoteHoldFlag;
}

#pragma mark - 快照字典（回调/快照上抛契约）

- (NSDictionary *)toDictionary
{
    return @{
        SipSessionKeySessionId:       @(self.sessionId),
        SipSessionKeyCallId:          @(self.callId),
        SipSessionKeyGroupId:         self.groupId ?: @"",
        SipSessionKeyDirection:       @(self.direction),
        SipSessionKeyIsIncoming:      @(self.isIncoming),
        SipSessionKeyRemoteNumber:    self.remoteNumber ?: @"",
        SipSessionKeyAccountName:     self.accountName ?: @"",
        SipSessionKeyRequestId:       self.requestId ?: @"",
        SipSessionKeyCallerIdName:    self.callerIdName ?: @"",
        SipSessionKeyCallStateView:   self.callStateView,
        /* isTerminal 判定唯一权威：随快照上抛，桥接层直读（不做六态重枚举） */
        SipSessionKeyIsTerminal:      @(self.isTerminal),
        SipSessionKeyPjsuaState:      @(self.pjsuaState),
        SipSessionKeyLastStatus:      @(self.lastStatus),
        SipSessionKeyHoldFlag:        @(self.holdFlag),
        SipSessionKeyRemoteHoldFlag:  @(self.remoteHoldFlag),
        SipSessionKeyMuteFlag:        @(self.muteFlag),
        SipSessionKeyAnswerRequested: @(self.answerRequested),
        SipSessionKeyCanBeAnswered:   @(self.canBeAnswered),
        SipSessionKeyIsOnHold:        @(self.isOnHold),
        SipSessionKeyCreatedAt:       @(self.createdAt),
        SipSessionKeyCallStartTime:   @(self.callStartTime),
        SipSessionKeyHoldStartTime:   @(self.holdStartTime),
        SipSessionKeyCallKitUuid:     self.callKitUuid.UUIDString ?: @"",
    };
}

- (NSString *)sessionDescription
{
    return [NSString stringWithFormat:
            @"CallSession{callId=%ld, dir=%@, view=%@, pjsua=%ld, last=%ld%@%@}",
            (long)self.callId,
            self.isIncoming ? @"in" : @"out",
            self.callStateView,
            (long)self.pjsuaState,
            (long)self.lastStatus,
            self.remoteNumber.length > 0
                ? [@", num=" stringByAppendingString:self.remoteNumber] : @"",
            self.requestId.length > 0
                ? [@", reqId=" stringByAppendingString:self.requestId] : @""];
}

@end
