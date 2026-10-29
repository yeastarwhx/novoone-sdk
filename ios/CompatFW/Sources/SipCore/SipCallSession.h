#ifndef SIP_CALL_SESSION_H_
#define SIP_CALL_SESSION_H_

/*
 * SipCallSession — 单路通话会话（字段模型对齐安卓 CallSession.java）。
 *
 * 线程模型：所有可变字段仅引擎主线程读写（引擎 dispatch 收敛 +
 * Registry 快照消费方在主线程），因此用可读写的公开 property 而
 * 非同步访问器——delegate 层同样必须在主线程读取。
 *
 * 视图状态（callStateView，由引擎按 pjsua state/last_status 映射写入）：
 *   呼出：Trying → Ringing → Established → Terminated/Busy/Error/Unauthorized
 *   来电：IncomingTrying → IncomingRinging →（接听）IncomingAnswered
 *                                      →（拒接）IncomingRejected
 *                                      →（对端取消）IncomingMissed
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* WebRTC ObjC 类型仅前向声明（对外无 C++ 泄漏） */
@class RTCPeerConnection;
@class RTCAudioSource;
@class RTCAudioTrack;

/* 方向（首事件定型，不随重协商变） */
typedef NS_ENUM(NSInteger, SipCallDirection) {
    SipCallDirectionOut = 0,
    SipCallDirectionIn  = 1,
};

/* 视图状态常量（对齐 JS 层 CallState 子集） */
FOUNDATION_EXPORT NSString * const SipCallStateTrying;
FOUNDATION_EXPORT NSString * const SipCallStateRinging;
FOUNDATION_EXPORT NSString * const SipCallStateEstablished;
FOUNDATION_EXPORT NSString * const SipCallStateTerminated;
FOUNDATION_EXPORT NSString * const SipCallStateBusy;
FOUNDATION_EXPORT NSString * const SipCallStateError;
FOUNDATION_EXPORT NSString * const SipCallStateUnauthorized;
FOUNDATION_EXPORT NSString * const SipCallStateIncomingTrying;
FOUNDATION_EXPORT NSString * const SipCallStateIncomingRinging;
FOUNDATION_EXPORT NSString * const SipCallStateIncomingAnswered;
FOUNDATION_EXPORT NSString * const SipCallStateIncomingRejected;
FOUNDATION_EXPORT NSString * const SipCallStateIncomingMissed;

/* toDictionary 字段键（回调/快照契约，桥接层组包用；禁止裸拼字符串） */
FOUNDATION_EXPORT NSString * const SipSessionKeySessionId;
FOUNDATION_EXPORT NSString * const SipSessionKeyCallId;
FOUNDATION_EXPORT NSString * const SipSessionKeyGroupId;
FOUNDATION_EXPORT NSString * const SipSessionKeyDirection;
FOUNDATION_EXPORT NSString * const SipSessionKeyIsIncoming;
FOUNDATION_EXPORT NSString * const SipSessionKeyRemoteNumber;
FOUNDATION_EXPORT NSString * const SipSessionKeyAccountName;
FOUNDATION_EXPORT NSString * const SipSessionKeyRequestId;
FOUNDATION_EXPORT NSString * const SipSessionKeyCallerIdName;
FOUNDATION_EXPORT NSString * const SipSessionKeyCallStateView;
FOUNDATION_EXPORT NSString * const SipSessionKeyIsTerminal;
FOUNDATION_EXPORT NSString * const SipSessionKeyPjsuaState;
FOUNDATION_EXPORT NSString * const SipSessionKeyLastStatus;
FOUNDATION_EXPORT NSString * const SipSessionKeyHoldFlag;
FOUNDATION_EXPORT NSString * const SipSessionKeyRemoteHoldFlag;
FOUNDATION_EXPORT NSString * const SipSessionKeyMuteFlag;
FOUNDATION_EXPORT NSString * const SipSessionKeyAnswerRequested;
FOUNDATION_EXPORT NSString * const SipSessionKeyCanBeAnswered;
FOUNDATION_EXPORT NSString * const SipSessionKeyIsOnHold;
FOUNDATION_EXPORT NSString * const SipSessionKeyCreatedAt;
FOUNDATION_EXPORT NSString * const SipSessionKeyCallStartTime;
FOUNDATION_EXPORT NSString * const SipSessionKeyHoldStartTime;
/* CallKit 会话 UUID（二阶段：来电 report/去电 startCall 绑定；空串=未绑定） */
FOUNDATION_EXPORT NSString * const SipSessionKeyCallKitUuid;

/* 毫秒时间戳（对齐安卓 System.currentTimeMillis 语义） */
FOUNDATION_EXPORT long long SipCurrentTimeMillis(void);

@interface SipCallSession : NSObject

/* ---------------- 标识 ---------------- */

/* 会话注册表内部键（创建即分配，与 pjsua callId 解耦：
 * 呼出会话在 INVITE 提交前尚无 callId） */
@property (nonatomic, readonly, assign) long long sessionId;

/* pjsua call id（呼出会话在 INVITE 提交前为 -1） */
@property (nonatomic, assign) NSInteger callId;

/* 呼出 groupId 前缀（命名空间隔离，见 groupId 属性注释） */
FOUNDATION_EXPORT NSString * const SipGroupIdOutgoingPrefix;

/* 会议组 shim：来电 groupId = String(callId)；呼出 groupId = 前缀 + String(sessionId)
 * （创建即赋且保持稳定，INVITE 提交获得 callId 后不改写）。
 * 呼出不能直接用 callId：ICE gather 窗口期 INVITE 未提交（callId=-1）；也不能
 * 裸用 sessionId 数字串：sessionId 与 callId 为两个独立计数器，首个呼出
 * sessionId=1 会与第二路来电 callId=1 撞号（同为 "1"），RN 侧两路通话同 id
 * "group_1" —— isStillAnswerable 按 id 定位来电误中呼出腿，组合操作第二步
 * 接听被跳过。前缀隔离两计数器后呼出 id 形如 "o1"（对齐
 * 安卓 callId 唯一语义；RN/桥接均按字符串等值匹配，不解析数字） */
@property (nonatomic, copy, nullable) NSString *groupId;

/* 方向：SipCallDirectionIn / SipCallDirectionOut（创建时锚定） */
@property (nonatomic, readonly, assign) SipCallDirection direction;

/* 对端 URI user 部分（呼出=被叫号码；来电=主叫号码） */
@property (nonatomic, copy, nullable) NSString *remoteNumber;

/* 账号显示名（From display，缺省回退 remoteNumber） */
@property (nonatomic, copy, nullable) NSString *accountName;

/* ---------------- 头缓存 ---------------- */

/* 来电：INVITE X-Request-ID 头；呼出：我方注入的 requestId */
@property (nonatomic, copy, nullable) NSString *requestId;

/* 来电：INVITE X-Nov-Caller-ID-Name 头（接通后仍可读） */
@property (nonatomic, copy, nullable) NSString *callerIdName;

/* CallKit 会话 UUID（来电 = reportNewIncomingCall 用的 uuid；呼出 =
 * CXStartCallAction 的 uuid。引擎主线程读写；快照上抛为 UUIDString） */
@property (nonatomic, strong, nullable) NSUUID *callKitUuid;

/* ---------------- 状态 ---------------- */

/* 最新 ys_pjsip_inv_state（SipWebrtcEngine 的 CALL_STATE_*） */
@property (nonatomic, assign) NSInteger pjsuaState;

/* 最后 SIP 响应码（180/200/486/...） */
@property (nonatomic, assign) NSInteger lastStatus;

/* 视图状态（SipCallState*，引擎按状态映射写入），初始 Trying */
@property (nonatomic, copy) NSString *callStateView;

/* ---------------- hold / mute ---------------- */

/* 本端主动 hold（track 静音 + sendonly 方向 re-INVITE） */
@property (nonatomic, assign) BOOL holdFlag;

/* 对端 hold（收到的 offer 方向非 sendrecv，如 sendonly） */
@property (nonatomic, assign) BOOL remoteHoldFlag;

/* 本端静音（track isEnabled=NO，不发 re-INVITE） */
@property (nonatomic, assign) BOOL muteFlag;

/* ---------------- 来电手动接听 ---------------- */

/* 来电 INVITE offer 缓存（callAnswer 时消费） */
@property (nonatomic, copy, nullable) NSString *offerSdp;

/* 已调 callAnswer（canBeAnswered 翻 false，防重复接听） */
@property (nonatomic, assign) BOOL answerRequested;

/* 已调 callReject 或保护性 486（终态归 IncomingRejected 的判据） */
@property (nonatomic, assign) BOOL rejectRequested;

/* 已调 callHangup（终态归 Terminated 而非 Missed 的判据） */
@property (nonatomic, assign) BOOL hangupRequested;

/* pjsua 到过 CONFIRMED（接通过；终态归 Terminated 而非 Missed 的判据） */
@property (nonatomic, assign) BOOL confirmedOnce;

/* ---------------- WebRTC（引擎主线程访问） ---------------- */

@property (nonatomic, strong, nullable) RTCPeerConnection *peerConnection;
@property (nonatomic, strong, nullable) RTCAudioSource *audioSource;
@property (nonatomic, strong, nullable) RTCAudioTrack *audioTrack;

/* ---------------- offer/answer 状态机 ---------------- */

/* caller: INVITE already sent */
@property (nonatomic, assign) BOOL inviteSent;
/* callee/re-INVITE: 本地 answer 已 set，等 ICE 候选发 200 */
@property (nonatomic, assign) BOOL answerPending;
/* callee/re-INVITE: 200 已发 */
@property (nonatomic, assign) BOOL answerSent;
/* 本地 offer（INVITE/re-INVITE）已发出，等对端 200 answer 应用 */
@property (nonatomic, assign) BOOL awaitingAnswer;
/* hold/resume: 本地 offer 已 set，等 ICE 候选发 re-INVITE */
@property (nonatomic, assign) BOOL reinvitePending;

/* ---------------- 时间戳（毫秒，引擎写入） ---------------- */

/* 会话创建时间 */
@property (nonatomic, assign) long long createdAt;
/* CONFIRMED 时间（callStartTime 契约字段），0 = 未接通 */
@property (nonatomic, assign) long long callStartTime;
/* 最近一次 hold 生效时间（holdStartTime 契约字段），0 = 未 hold */
@property (nonatomic, assign) long long holdStartTime;
/* 进入终态时间（0 = 未终态） */
@property (nonatomic, assign) long long terminatedAt;
/* 终态延迟清除时间（Registry 到点移除出 callList），0 = 未排期 */
@property (nonatomic, assign) long long finalizeRemoveAt;

/* ---------------- ICE gathering 看门狗（引擎主线程 NSTimer） ---------------- */

@property (nonatomic, strong, nullable) NSTimer *gatherWatchdog;

/* ---------------- 构造（Registry 专用） ---------------- */

- (instancetype)initWithSessionId:(long long)sessionId
                         direction:(SipCallDirection)direction NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* ---------------- 判定（契约字段） ---------------- */

/* 是否终态（Registry 判定 linger/容量用；并经 toDictionary 以
 * SipSessionKeyIsTerminal 上抛，桥接层兜底选择直读该键——终态
 * 状态集仅此一处维护，桥侧不得再复制六态字符串集合人工同步） */
- (BOOL)isTerminal;

/* 是否呼入方向 */
- (BOOL)isIncoming;

/* canBeAnswered 契约：IncomingRinging 且尚未接听且 offer 已缓存 */
- (BOOL)canBeAnswered;

/* isOnHold 契约：本端或对端 hold 均置位（视图展示语义） */
- (BOOL)isOnHold;

/* 快照字典（回调/快照上抛契约，键为 SipSessionKey* 常量） */
- (NSDictionary *)toDictionary;

/* 排查日志用摘要（对齐安卓 toString） */
- (NSString *)sessionDescription;

@end

NS_ASSUME_NONNULL_END

#endif /* SIP_CALL_SESSION_H_ */
