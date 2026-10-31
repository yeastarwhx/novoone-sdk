//
//  SipCallKitCoordinator.mm
//  NovoOneApp
//
//  CallKit 协作模块实现（detail-design §4.3）。行为基准对齐线上
//  Softphone_Cx_Delegate：cxCallUpdate 定制（supportsGrouping/Ungrouping=false、
//  localizedCallerName=displayName、分机 ^[0-9]{1,6}$ → generic handle）。
//
//  动作落点（均回引擎执行，coordinator 无独立通话状态）：
//    CXAnswerCallAction → engine.callAnswer:（fulfill 在引擎 200 发出后）
//    CXEndCallAction    → engine.callEndFromCallKit:（振铃 486 / 通话 BYE 分流）
//    CXStartCallAction  → fulfill 后执行呼出块（App 发起）或引擎直呼（记录回拨）
//    didActivate/Deactivate → engine 音频会话激活线（useManualAudio 模式）
//
//  Created for phase-2 task: iOS background call (10-15).
//

#import "SipCallKitCoordinator.h"

#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>

#import "SipCallSession.h"
#import "SipCallSessionRegistry.h"
#import "SipCoreLogger.h"
#import "SipWebrtcEngine.h"

/* 分机号判定（对齐线上 Softphone_Cx_Delegate 正则） */
static NSString * const kExtensionPattern = @"^[0-9]{1,6}$";
/* 推送 report 后 INVITE 未到达的兜底撤销（异常矩阵：服务器丢 INVITE；
 * 绝对上限，含弱网注册重试耗时） */
static NSTimeInterval const kPendingReportWatchdogSec = 45.0;
/* 注册 200 后 INVITE 下发窗口：push 唤醒注册后服务器立即下发 pending
 * INVITE（实测 0.5-0.6s 到达），主叫提前挂断（服务器下发前 CANCEL，
 * 只发 miss push——普通 APNs 通知，SDK 不可见）不再有 INVITE——窗口
 * 过后仍 pending 的上报以未接撤销；5s = 3s 观测上限 + 服务器抖动余量 */
static NSTimeInterval const kPostRegisterInviteWindowSec = 5.0;
/* 接听动作看门狗：CXAnswer 后 200 迟迟未发（SRD/ICE 卡死），收掉系统动作 */
static NSTimeInterval const kAnswerActionTimeoutSec = 8.0;
/* 去电动作看门狗：CXStartCallAction 8s 未回调 → 直呼兜底（保通话可用性） */
static NSTimeInterval const kStartActionTimeoutSec = 8.0;

#define ckLog(...) \
    [SipCoreLogger logWithPrefix:SipLogPrefixEngine format:@"[CALLKIT] " __VA_ARGS__]

static NSString *CallKitReasonName(SipCallKitEndedReason reason)
{
    switch (reason) {
        case SipCallKitEndedReasonFailed:           return @"failed";
        case SipCallKitEndedReasonRemoteEnded:      return @"remoteEnded";
        case SipCallKitEndedReasonUnanswered:       return @"unanswered";
        case SipCallKitEndedReasonAnsweredElsewhere:return @"answeredElsewhere";
    }
    return @"unknown";
}

#pragma mark - 待关联上报登记（push report 先行，INVITE 后到）

@interface SipPendingReport : NSObject
@property (nonatomic, strong) NSUUID *uuid;
@property (nonatomic, copy) NSString *callerNumber;
@property (nonatomic, strong, nullable) NSTimer *watchdog;
@end

@implementation SipPendingReport
- (void)dealloc
{
    [self.watchdog invalidate];
}
@end

#pragma mark - Coordinator

@interface SipCallKitCoordinator () <CXProviderDelegate>
@property (nonatomic, weak, nullable) SipWebrtcEngine *engine;
@property (nonatomic, strong) CXProvider *provider;
@property (nonatomic, strong) CXCallController *callController;
/* push 先行 report 未关联 SIP 会话的登记（FIFO，matchIncoming 消费） */
@property (nonatomic, strong) NSMutableArray<SipPendingReport *> *pendingReports;
/* 已执行 CXAnswer 未 fulfill 的动作（uuid 键；引擎 200 发出后 fulfill） */
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, CXAnswerCallAction *> *pendingAnswers;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, NSTimer *> *answerWatchdogs;
/* 去电：CXStartCallAction fulfill 后执行的呼出块（uuid 键） */
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, void (^)(NSUUID *)> *pendingStartBlocks;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, NSTimer *> *startWatchdogs;
/* 看门狗已兜底直呼的 uuid：迟到的 start action 到达时据此跳过二次呼出
 * （block 已弹出，else 分支会误判为系统记录回拨）；sessionEnded 清理 */
@property (nonatomic, strong) NSMutableSet<NSUUID *> *fallbackDialedUuids;
/* 已 fulfill 的 CXEndCallAction 的 uuid（用户经系统卡片拒接/挂断——系统侧
 * 已收口，sessionEnded 不再 reportCallEnded 重复上报） */
@property (nonatomic, strong) NSMutableSet<NSUUID *> *endActionUuids;
/* 系统通话记录开关（SoftphonePreferences.includesCallKitCallsInRecent 落点）：
 * enabled = 目标值，providerInRecents = 现 provider configuration 值 */
@property (nonatomic, assign) BOOL callsInRecentsEnabled;
@property (nonatomic, assign) BOOL providerCallsInRecents;
@end

@implementation SipCallKitCoordinator

#pragma mark - 生命周期

- (instancetype)initWithEngine:(SipWebrtcEngine *)engine
{
    self = [super init];
    if (self) {
        _engine = engine;
        _pendingReports = [[NSMutableArray alloc] init];
        _pendingAnswers = [[NSMutableDictionary alloc] init];
        _answerWatchdogs = [[NSMutableDictionary alloc] init];
        _pendingStartBlocks = [[NSMutableDictionary alloc] init];
        _startWatchdogs = [[NSMutableDictionary alloc] init];
        _endActionUuids = [[NSMutableSet alloc] init];
        _fallbackDialedUuids = [[NSMutableSet alloc] init];

        _callsInRecentsEnabled = YES;
        _providerCallsInRecents = YES;
        CXProviderConfiguration *config = [self providerConfigurationWithCallsInRecents:_callsInRecentsEnabled];
        ckLog(@"coordinator ready (icon=app default)");

        _provider = [[CXProvider alloc] initWithConfiguration:config];
        [_provider setDelegate:self queue:dispatch_get_main_queue()];
        _callController = [[CXCallController alloc] initWithQueue:dispatch_get_main_queue()];
    }
    return self;
}

- (void)dealloc
{
    for (NSTimer *timer in self.answerWatchdogs.allValues) { [timer invalidate]; }
    for (NSTimer *timer in self.startWatchdogs.allValues) { [timer invalidate]; }
    self.answerWatchdogs = nil;
    self.startWatchdogs = nil;
}

/* provider 配置（唯一构造点——init 与运行期重建共用）。
 * 图标：iOS 14 起 config.icon 移除（iOS 26 SDK 无该属性），系统卡片
 * 回落 App 图标；iconTemplateImageData 需 40pt 模板位图，接入期
 * 暂不设置（默认回落 App 图标） */
- (CXProviderConfiguration *)providerConfigurationWithCallsInRecents:(BOOL)inRecents
{
    CXProviderConfiguration *config = [[CXProviderConfiguration alloc] init];
    config.supportsVideo = NO;
    config.maximumCallGroups = 1;
    config.maximumCallsPerCallGroup = 1;
    config.supportedHandleTypes = [NSSet setWithObjects:
                                   @(CXHandleTypeGeneric), @(CXHandleTypePhoneNumber), nil];
    config.includesCallsInRecents = inRecents;   /* 系统通话记录（AC-6 回拨） */
    return config;
}

#pragma mark - 系统通话记录开关（provider 重建线）

- (void)setCallsInRecentsEnabled:(BOOL)enabled
{
    _callsInRecentsEnabled = enabled;
    [self rebuildProviderIfNeeded];
}

/* 目标值 != provider 现值且无活跃通话时重建 provider（includesCallsInRecents
 * 只能在 configuration 上定，无热改 API）。活跃通话期间挂起，由下一通
 * report/start 入口重试——期间终态 linger 会话也计入活跃（其
 * reportCallEnded 仍走旧 provider 引用，重建会丢失上报通道） */
- (void)rebuildProviderIfNeeded
{
    if (self.callsInRecentsEnabled == self.providerCallsInRecents) { return; }
    if (![self canRebuildProvider]) {
        ckLog(@"calls-in-recents %d deferred (active calls)", self.callsInRecentsEnabled);
        return;
    }
    self.provider = [[CXProvider alloc] initWithConfiguration:
        [self providerConfigurationWithCallsInRecents:self.callsInRecentsEnabled]];
    [self.provider setDelegate:self queue:dispatch_get_main_queue()];
    self.providerCallsInRecents = self.callsInRecentsEnabled;
    ckLog(@"provider rebuilt (callsInRecents=%d)", self.callsInRecentsEnabled);
}

- (BOOL)canRebuildProvider
{
    return ![self.engine hasAnySession]
        && self.pendingReports.count == 0
        && self.pendingAnswers.count == 0
        && self.pendingStartBlocks.count == 0;
}

/* 会话终态后在 linger 过期点复查一次重建：来电（handleIncomingSdp）与
 * 呼出（callOut）都是先建会话再进 report/start 入口，入口重试在这些
 * 路径恒遇活跃会话——挂起的开关变更依赖本复查在"通话结束 → linger
 * 清除"后的空窗生效。幂等：值未变/仍有通话则 no-op；复查时又有新通话
 * 则其自身 sessionEnded 会再排 */
- (void)scheduleProviderRebuildAfterLinger
{
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
            (SipCallSessionRegistry.terminalLingerMs + 1000) * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            [self rebuildProviderIfNeeded];
        });
}

#pragma mark - 来电上报（PushKit 红线路径）

- (NSUUID *)reportIncomingCall:(NSUUID *)uuid
                    callerName:(NSString *)callerName
                  callerNumber:(NSString *)callerNumber
{
    [self rebuildProviderIfNeeded];
    NSUUID *callUuid = (uuid != nil) ? uuid : [NSUUID UUID];
    NSString *name = [self trimmedString:callerName];
    NSString *number = [self trimmedString:callerNumber];

    CXCallUpdate *update = [[CXCallUpdate alloc] init];
    /* 对齐线上 Softphone_Cx_Delegate：单路通话，无保持/合并/分离 */
    update.supportsHolding = NO;
    update.supportsGrouping = NO;
    update.supportsUngrouping = NO;
    update.hasVideo = NO;
    NSString *address = (number.length > 0) ? number : ((name.length > 0) ? name : @"Unknown");
    update.remoteHandle = [self handleForAddress:address];
    if (name.length > 0) {
        update.localizedCallerName = name;
    }

    __weak SipCallKitCoordinator *weakSelf = self;
    [self.provider reportNewIncomingCallWithUUID:callUuid update:update
                                      completion:^(NSError *error) {
        /* 系统 completion 不保证主队列（coordinator 状态仅主线程读写），
         * 统一转投主线程后再动登记 */
        dispatch_async(dispatch_get_main_queue(), ^{
            SipCallKitCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            if (error != nil) {
                ckLog(@"report FAILED (uuid=%@): %@ — 解绑会话走 RN 弹屏兜底",
                      callUuid.UUIDString, error.localizedDescription);
                [strongSelf removePendingReportForUuid:callUuid];
                /* 系统卡片不可用：解绑已绑定的会话 uuid，未接听来电重新
                 * 进入 RN 快照（snapshotCalls 按 uuid 绑定过滤），来电屏
                 * 回退一阶段 RN 弹屏兜底（detail-design 4.3.4 异常矩阵） */
                [strongSelf.engine onCallKitReportFailedForUuid:callUuid];
                return;
            }
            ckLog(@"report OK (uuid=%@, name=%@, number=%@)",
                  callUuid.UUIDString, name, number);
        });
    }];

    SipPendingReport *entry = [[SipPendingReport alloc] init];
    entry.uuid = callUuid;
    entry.callerNumber = (number.length > 0) ? number : name;
    [self.pendingReports addObject:entry];
    [self armPendingReportWatchdog:entry];
    return callUuid;
}

- (NSUUID *)matchIncoming:(NSString *)remoteNumber
{
    NSString *target = [self trimmedString:remoteNumber];
    if (target.length == 0) { return nil; }
    for (SipPendingReport *entry in [self.pendingReports copy]) {
        if ([entry.callerNumber isEqualToString:target]) {
            [self removePendingReportForUuid:entry.uuid];
            ckLog(@"match HIT (uuid=%@, number=%@, remain=%lu)",
                  entry.uuid.UUIDString, target, (unsigned long)self.pendingReports.count);
            return entry.uuid;
        }
    }
    ckLog(@"match MISS (number=%@, pending=%lu)",
          target, (unsigned long)self.pendingReports.count);
    return nil;
}

- (void)onSessionBound:(NSUUID *)uuid
{
    SipPendingReport *entry = [self pendingReportForUuid:uuid];
    if (entry != nil) {
        [self removePendingReportForUuid:uuid];
        ckLog(@"session bound (uuid=%@) — pending report consumed", uuid.UUIDString);
    }
    /* 接听先于 INVITE 到达（推送先行卡片被秒接）：会话绑定后补执行接听。
     * 引擎 callAnswer 幂等（answerRequested 去重），重复调用无副作用 */
    CXAnswerCallAction *deferred = self.pendingAnswers[uuid];
    if (deferred != nil) {
        NSInteger callId = (self.engine != nil) ? [self.engine callIdForCallKitUuid:uuid] : -1;
        if (callId >= 0) {
            ckLog(@"deferred answer resumed after bind (callId=%ld, uuid=%@)",
                  (long)callId, uuid.UUIDString);
            [self.engine callAnswer:callId];
        }
    }
}

- (void)onRegistered
{
    for (SipPendingReport *entry in [self.pendingReports copy]) {
        ckLog(@"registered — pending report window shortened (uuid=%@)",
              entry.uuid.UUIDString);
        [self armPendingReportWatchdog:entry interval:kPostRegisterInviteWindowSec];
    }
}

#pragma mark - 接听动作 fulfill 线（引擎 200 发出/失败回挂）

- (void)onAnswerSentForUuid:(NSUUID *)uuid
{
    [self cancelAnswerWatchdogForUuid:uuid];
    CXAnswerCallAction *action = self.pendingAnswers[uuid];
    if (action == nil) { return; }   /* 非 CallKit 接听或已超时收掉 */
    [self.pendingAnswers removeObjectForKey:uuid];
    ckLog(@"answer action fulfilled (200 sent, uuid=%@)", uuid.UUIDString);
    [action fulfill];
}

- (void)onAnswerFailedForUuid:(NSUUID *)uuid
{
    CXAnswerCallAction *action = self.pendingAnswers[uuid];
    if (action == nil) { return; }
    [self.pendingAnswers removeObjectForKey:uuid];
    [self cancelAnswerWatchdogForUuid:uuid];
    ckLog(@"answer action failed (uuid=%@) — 终态上报由 sessionEnded 驱动",
          uuid.UUIDString);
    [action fail];
}

- (void)failPendingAnswerForUuid:(NSUUID *)uuid
{
    CXAnswerCallAction *action = self.pendingAnswers[uuid];
    if (action == nil) { return; }
    [self.pendingAnswers removeObjectForKey:uuid];
    [self cancelAnswerWatchdogForUuid:uuid];
    ckLog(@"pending answer dropped (uuid=%@)", uuid.UUIDString);
    [action fail];
    /* 会话从未绑定（INVITE 未到）时 answer fail 后系统卡片滞留响铃，
     * 强制收口（见 endUnboundCallForUuid；已绑定场景登记已消费，no-op） */
    [self endUnboundCallForUuid:uuid];
}

/* 会话未绑定 call 的强制收口：answer 被 fail / end action fulfill 之后，
 * 系统侧 call 实测仍滞留响铃（CallKit 对 fail 过 answer 的 call，end
 * action fulfill 不撤卡，action 反而 timedOut），reportCallEnded 是唯一
 * 可靠终结。幂等——无登记时 no-op；有会话路径的终态上报由 sessionEnded
 * 统一驱动（reason 映射在那里），不经此 */
- (void)endUnboundCallForUuid:(NSUUID *)uuid
{
    if ([self pendingReportForUuid:uuid] == nil) { return; }
    [self removePendingReportForUuid:uuid];
    [self.provider reportCallWithUUID:uuid endedAtDate:[NSDate date]
                                reason:CXCallEndedReasonUnanswered];
    ckLog(@"unbound call ended (reportCallEnded unanswered, uuid=%@)",
          uuid.UUIDString);
}

#pragma mark - 终态上报

- (void)onEngineEndNoSessionForUuid:(NSUUID *)uuid
{
    /* end action 登记后引擎侧会话已不存在（runOnMain 派发间隙终结）：
     * sessionEnded 无从消费登记，此处清除防泄漏；action 已 fulfill，
     * 系统卡片已收口，无需 reportCallEnded */
    if ([self.endActionUuids containsObject:uuid]) {
        [self.endActionUuids removeObject:uuid];
        ckLog(@"end action uuid cleaned (engine no session, uuid=%@)",
              uuid.UUIDString);
    }
}

- (void)sessionEnded:(SipCallSession *)session
{
    NSUUID *uuid = session.callKitUuid;
    if (uuid == nil) { return; }
    [self scheduleProviderRebuildAfterLinger];
    /* fallbackDialedUuids 此处不清：迟到 start action 可能晚于会话终态
     * （8s 看门狗兜底直呼 → 快速 4xx → sessionEnded，系统才回调 start
     * action），终态即清会把双呼保护撤在迟到动作到达之前；集合仅
     * coordinator 异常的兜底路径触达（每 uuid 一项），命中迟到动作时
     * 消费、生命周期内不清理无碍 */
    [self failPendingAnswerForUuid:uuid];
    [self cancelStartWatchdogForUuid:uuid];
    /* 用户经系统卡片拒接/挂断（CXEndCallAction 已 fulfill）：系统侧已收口，
     * 重复 reportCallEnded 会在通话记录覆盖"拒接/取消"语义 */
    if ([self.endActionUuids containsObject:uuid]) {
        [self.endActionUuids removeObject:uuid];
        ckLog(@"session ended via CallKit end action — skip report (uuid=%@)",
              uuid.UUIDString);
        return;
    }
    SipCallKitEndedReason reason = [self endedReasonForSession:session];
    [self.provider reportCallWithUUID:uuid endedAtDate:[NSDate date]
                                reason:(CXCallEndedReason)reason];
    ckLog(@"session ended -> report (uuid=%@, reason=%@, view=%@)",
          uuid.UUIDString, CallKitReasonName(reason), session.callStateView);
}

/* 终态 → CXCallEndedReason 映射（detail-design 4.3.2 步骤 3，按 iOS 26 SDK
 * 实际枚举值修正：无 Declined——振铃期拒接归 Unanswered，系统通话记录
 * 按未接呈现） */
- (SipCallKitEndedReason)endedReasonForSession:(SipCallSession *)session
{
    if (session.rejectRequested) {
        if (session.answerRequested && !session.confirmedOnce) {
            /* 接听链失败的保护性 486（媒体/信令未立）——系统记 failed */
            return SipCallKitEndedReasonFailed;
        }
        /* 振铃期主动拒接（RN 侧 486；系统卡片侧拒接走 endActionUuids 跳过） */
        return SipCallKitEndedReasonUnanswered;
    }
    if (session.isIncoming && !session.confirmedOnce && !session.hangupRequested) {
        return SipCallKitEndedReasonUnanswered; /* 对端取消/未接超时 */
    }
    if ([session.callStateView isEqualToString:SipCallStateError]
        || [session.callStateView isEqualToString:SipCallStateBusy]
        || [session.callStateView isEqualToString:SipCallStateUnauthorized]) {
        return SipCallKitEndedReasonFailed;
    }
    return SipCallKitEndedReasonRemoteEnded;
}

#pragma mark - 去电（App 发起 / 系统记录回拨统一入口）

- (void)startCall:(NSString *)number
        requestId:(NSString *)requestId
    makeCallBlock:(void (^)(NSUUID *))onActionFulfilled
{
    [self rebuildProviderIfNeeded];
    NSUUID *uuid = [NSUUID UUID];
    NSString *address = [self trimmedString:number];
    CXStartCallAction *action =
        [[CXStartCallAction alloc] initWithCallUUID:uuid
                                             handle:[self handleForAddress:address]];
    self.pendingStartBlocks[uuid] = onActionFulfilled;
    [self armStartWatchdogForUuid:uuid];
    __weak SipCallKitCoordinator *weakSelf = self;
    [self.callController requestTransactionWithAction:action
                                            completion:^(NSError *error) {
        /* 系统 completion 不保证主队列（coordinator 状态仅主线程读写） */
        dispatch_async(dispatch_get_main_queue(), ^{
            SipCallKitCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            if (error != nil) {
                ckLog(@"startCall transaction FAILED (uuid=%@): %@ — 直呼兜底",
                      uuid.UUIDString, error.localizedDescription);
                [strongSelf fireStartFallbackForUuid:uuid];
            } else {
                ckLog(@"startCall transaction OK (uuid=%@, number=%@, requestId=%@)",
                      uuid.UUIDString, address, requestId ?: @"-");
            }
        });
    }];
}

/* 直呼兜底：系统 8s 未回调 action（或交易失败）时绕过 CallKit 发起呼出，
 * 保通话可用性优先——系统通话记录由 RN/App 内 UI 自行兜底 */
- (void)fireStartFallbackForUuid:(NSUUID *)uuid
{
    void (^makeCall)(NSUUID *) = self.pendingStartBlocks[uuid];
    [self cancelStartWatchdogForUuid:uuid];
    if (makeCall == nil) { return; }   /* 已执行/已收掉 */
    [self.pendingStartBlocks removeObjectForKey:uuid];
    /* 标记已兜底直呼：迟到的 start action 据此跳过（else 分支无此标记
     * 会误判系统记录回拨再呼一次——同号双呼、两会话共用 uuid） */
    [self.fallbackDialedUuids addObject:uuid];
    ckLog(@"startCall fallback -> direct dial (uuid=%@)", uuid.UUIDString);
    makeCall(uuid);
}

#pragma mark - CXProviderDelegate（主队列）

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action
{
    NSInteger callId = (self.engine != nil) ? [self.engine callIdForCallKitUuid:action.callUUID] : -1;
    if (callId < 0) {
        /* 推送先行卡片被秒接（INVITE 未到、会话未绑定）：挂起等绑定后
         * 补执行（onSessionBound），8s 看门狗内 INVITE 未到则收动作 */
        ckLog(@"answer before INVITE bound (uuid=%@) — deferring", action.callUUID.UUIDString);
        self.pendingAnswers[action.callUUID] = action;
        [self armAnswerWatchdogForUuid:action.callUUID];
        return;
    }
    ckLog(@"answer action IN (callId=%ld, uuid=%@)", (long)callId, action.callUUID.UUIDString);
    self.pendingAnswers[action.callUUID] = action;
    [self armAnswerWatchdogForUuid:action.callUUID];
    /* fulfill 延后到引擎 200 发出（onAnswerSentForUuid）——防系统 UI 先行
     * 显示接通而媒体未立（detail 4.3.2） */
    [self.engine callAnswer:callId];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action
{
    NSInteger callId = (self.engine != nil) ? [self.engine callIdForCallKitUuid:action.callUUID] : -1;
    ckLog(@"end action IN (callId=%ld, uuid=%@)", (long)callId, action.callUUID.UUIDString);
    if (callId >= 0) {
        /* 先登记再去终结：callEndFromCallKit 内部 runOnMain 在主线程同步
         * 执行（reject/hangup → onSessionTerminated → sessionEnded），
         * sessionEnded 检查 endActionUuids 时 uuid 必须已登记，否则终态
         * 重复 reportCallEnded（系统侧 end action fulfill 已收口） */
        [self.endActionUuids addObject:action.callUUID];
        /* 引擎按会话状态分流：振铃中 → 486 拒接；通话中 → BYE/CANCEL */
        [self.engine callEndFromCallKit:callId uuid:action.callUUID];
    } else {
        /* 窗口期呼出（gather 未完成 callId=-1，会话存在）：引擎本地终结
         * （INVITE 已提交的竞态窗口照常 BYE/CANCEL）；与上方 callId>=0
         * 分支同不变量——先登记再终结（endUnboundOutgoing 内部 runOnMain
         * 主线程同步 → onSessionTerminated → sessionEnded 即时回查，晚
         * 登记则防重复 reportCallEnded 失效）；未终结（无会话/已终态）
         * 则撤销登记，否则残留无人消费 */
        if (self.engine != nil) {
            [self.endActionUuids addObject:action.callUUID];
            if (![self.engine endUnboundOutgoingForUuid:action.callUUID]) {
                [self.endActionUuids removeObject:action.callUUID];
            }
        }
        /* 会话未绑定的来电（report 后 INVITE 未到即拒接/挂断）：fulfill 实测
         * 不足以撤卡（系统 call 滞留响铃），补 reportCallEnded 强制收口
         * （无登记时 no-op）；endActionUuids 不登记（无会话即无
         * sessionEnded 消费，登记即泄漏） */
        [self endUnboundCallForUuid:action.callUUID];
    }
    [self failPendingAnswerForUuid:action.callUUID];   /* 拒接时挂起 answer 不可能再成功 */
    [action fulfill];
    /* 终态 reason 上报由引擎 sessionEnded 驱动（endActionUuids 命中则跳过） */
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action
{
    NSInteger callId = (self.engine != nil) ? [self.engine callIdForCallKitUuid:action.callUUID] : -1;
    if (callId >= 0) {
        [self.engine callHold:callId held:action.isOnHold];
    }
    ckLog(@"setHeld action (callId=%ld, held=%@)", (long)callId, @(action.isOnHold));
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action
{
    NSString *number = (action.handle.value != nil) ? action.handle.value : @"";
    [self cancelStartWatchdogForUuid:action.callUUID];
    void (^makeCall)(NSUUID *) = self.pendingStartBlocks[action.callUUID];
    [action fulfill];
    if (makeCall != nil) {
        /* App 内发起（RN callMake / SceneDelegate）：fulfill 后引擎呼出 */
        [self.pendingStartBlocks removeObjectForKey:action.callUUID];
        ckLog(@"start action fulfilled -> engine dial (number=%@, uuid=%@)",
              number, action.callUUID.UUIDString);
        makeCall(action.callUUID);
    } else if ([self.fallbackDialedUuids containsObject:action.callUUID]) {
        /* 看门狗已兜底直呼（系统回调晚于 8s）：跳过二次呼出，只收动作 */
        [self.fallbackDialedUuids removeObject:action.callUUID];
        ckLog(@"late start action after fallback dial — skip duplicate (uuid=%@)",
              action.callUUID.UUIDString);
        return;
    } else {
        /* 系统通话记录回拨（App 未发起，无 requestId）：引擎直呼 + 事件通知
         * RN 拉起去电 UI（AC-6） */
        ckLog(@"start action from recents -> engine dial (number=%@, uuid=%@)",
              number, action.callUUID.UUIDString);
        [self.engine callMake:number requestId:nil callKitUuid:action.callUUID];
        [self.engine notifyCallKitEvent:@{
            @"action": @"startCall",
            @"source": @"recents",
            @"uuid": action.callUUID.UUIDString,
            @"remoteNumber": number,
        }];
    }
}

/* 音频会话激活线：CallKit 模式（useManualAudio=YES）下音频单元启停唯一驱动源。
 * 注意来源是 CXProviderDelegate（非 RTCAudioSessionDelegate） */
- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession
{
    ckLog(@"audio session didActivate");
    [self.engine onCallKitAudioSessionActivated];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession
{
    ckLog(@"audio session didDeactivate");
    [self.engine onCallKitAudioSessionDeactivated];
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action
{
    ckLog(@"action timed out (%@)", NSStringFromClass([action class]));
    if ([action isKindOfClass:[CXAnswerCallAction class]]) {
        [self failPendingAnswerForUuid:((CXCallAction *)action).callUUID];
    }
}

- (void)providerDidReset:(CXProvider *)provider
{
    ckLog(@"provider DID RESET — 清空挂起动作与登记（SIP 会话由引擎自管理）");
    for (NSUUID *uuid in [self.pendingAnswers.allKeys copy]) {
        [self failPendingAnswerForUuid:uuid];
    }
    for (NSUUID *uuid in [self.pendingStartBlocks.allKeys copy]) {
        [self fireStartFallbackForUuid:uuid];
    }
    for (SipPendingReport *entry in [self.pendingReports copy]) {
        [self removePendingReportForUuid:entry.uuid];
        [self.provider reportCallWithUUID:entry.uuid endedAtDate:[NSDate date]
                                    reason:CXCallEndedReasonFailed];
    }
}

#pragma mark - 看门狗（引擎主线程持有，block 弱引用 self）

- (void)armPendingReportWatchdog:(SipPendingReport *)entry
{
    [self armPendingReportWatchdog:entry interval:kPendingReportWatchdogSec];
}

- (void)armPendingReportWatchdog:(SipPendingReport *)entry
                         interval:(NSTimeInterval)interval
{
    __weak SipCallKitCoordinator *weakSelf = self;
    NSUUID *uuid = entry.uuid;
    [entry.watchdog invalidate];   /* 重 arm（注册后缩短窗口）先撤销旧计时 */
    entry.watchdog = [NSTimer scheduledTimerWithTimeInterval:interval
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        SipCallKitCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [strongSelf removePendingReportForUuid:uuid];
        [strongSelf.provider reportCallWithUUID:uuid endedAtDate:[NSDate date]
                                          reason:CXCallEndedReasonUnanswered];
        ckLog(@"pending report watchdog: INVITE 未达（%.0fs 窗口），撤销卡片 (uuid=%@)",
              interval, uuid.UUIDString);
    }];
}

- (void)armAnswerWatchdogForUuid:(NSUUID *)uuid
{
    __weak SipCallKitCoordinator *weakSelf = self;
    [self cancelAnswerWatchdogForUuid:uuid];
    self.answerWatchdogs[uuid] = [NSTimer scheduledTimerWithTimeInterval:kAnswerActionTimeoutSec
                                                                 repeats:NO
                                                                   block:^(NSTimer *timer) {
        SipCallKitCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        ckLog(@"answer watchdog: 200 未按时发出，收掉系统动作 (uuid=%@)",
              uuid.UUIDString);
        [strongSelf failPendingAnswerForUuid:uuid];
    }];
}

- (void)cancelAnswerWatchdogForUuid:(NSUUID *)uuid
{
    NSTimer *timer = self.answerWatchdogs[uuid];
    if (timer != nil) {
        [timer invalidate];
        [self.answerWatchdogs removeObjectForKey:uuid];
    }
}

- (void)armStartWatchdogForUuid:(NSUUID *)uuid
{
    __weak SipCallKitCoordinator *weakSelf = self;
    [self cancelStartWatchdogForUuid:uuid];
    self.startWatchdogs[uuid] = [NSTimer scheduledTimerWithTimeInterval:kStartActionTimeoutSec
                                                                repeats:NO
                                                                  block:^(NSTimer *timer) {
        SipCallKitCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [strongSelf fireStartFallbackForUuid:uuid];
    }];
}

- (void)cancelStartWatchdogForUuid:(NSUUID *)uuid
{
    NSTimer *timer = self.startWatchdogs[uuid];
    if (timer != nil) {
        [timer invalidate];
        [self.startWatchdogs removeObjectForKey:uuid];
    }
}

#pragma mark - 登记存取

- (nullable SipPendingReport *)pendingReportForUuid:(NSUUID *)uuid
{
    for (SipPendingReport *entry in self.pendingReports) {
        if ([entry.uuid isEqual:uuid]) { return entry; }
    }
    return nil;
}

- (void)removePendingReportForUuid:(NSUUID *)uuid
{
    SipPendingReport *entry = [self pendingReportForUuid:uuid];
    if (entry == nil) { return; }
    [entry.watchdog invalidate];
    entry.watchdog = nil;
    [self.pendingReports removeObject:entry];
    /* 最后一笔 pending 撤销（watchdog 超时/窗口收口/系统拒接/report 失败）
     * 且无会话时是 provider 重建空窗——冷启动 PushKit report 后才收到
     * 偏好覆盖的场景在此恢复。会话先行路径的撤销为 no-op（复查时仍有
     * 会话，其 sessionEnded 自会再排） */
    if (self.pendingReports.count == 0) {
        [self scheduleProviderRebuildAfterLinger];
    }
}

#pragma mark - 工具

- (NSString *)trimmedString:(NSString *)text
{
    if (text == nil) { return @""; }
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/* 分机 ^[0-9]{1,6}$ → generic；其余（含 +86 长号）→ phoneNumber（对齐线上） */
- (CXHandle *)handleForAddress:(NSString *)address
{
    NSPredicate *extensionTest =
        [NSPredicate predicateWithFormat:@"SELF MATCHES %@", kExtensionPattern];
    BOOL isExtension = [extensionTest evaluateWithObject:address];
    CXHandleType type = isExtension ? CXHandleTypeGeneric : CXHandleTypePhoneNumber;
    return [[CXHandle alloc] initWithType:type value:address];
}

@end
