//
//  SipCallKitCoordinator.h
//  NovoOneApp
//
//  CallKit 协作模块（detail-design §4.3）：CXProvider/CXCallController 封装，
//  收敛 CallKit 全部状态变化——动作（answer/end/start）、音频会话激活线、
//  会话 UUID 映射。桥接层只透传事件（onCallKitEvent），不持有 CallKit 状态。
//
//  线程纪律：provider delegate 绑定主队列；coordinator 全部方法仅主线程调用
//  （引擎侧调用点均在 runOnMain 内）。
//
//  Created for phase-2 task: iOS background call (10-15).
//

#ifndef SIP_CALLKIT_COORDINATOR_H
#define SIP_CALLKIT_COORDINATOR_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SipWebrtcEngine;
@class SipCallSession;

/* CallKit 终结原因（数值对齐 CXCallEndedReason——iOS 26 SDK 枚举 1..5，
 * 无 Declined 值：用户经系统卡片拒接走 CXEndCallAction fulfill 收口，
 * 不经 reportCallEnded 上报） */
typedef NS_ENUM(NSInteger, SipCallKitEndedReason) {
    SipCallKitEndedReasonFailed = 1,
    SipCallKitEndedReasonRemoteEnded = 2,
    SipCallKitEndedReasonUnanswered = 3,
    SipCallKitEndedReasonAnsweredElsewhere = 4,
};

@interface SipCallKitCoordinator : NSObject

/* 引擎持有（弱引用，动作落回引擎方法执行；引擎 init 时创建——冷启动推送
 * 先于 engineStart 到达时仍可 report） */
- (instancetype)initWithEngine:(SipWebrtcEngine *)engine;

#pragma mark - 来电上报（PushKit 红线路径）

/* 来电上报：同步发起 reportNewIncomingCall 后返回（Apple 红线：push 回调
 * 返回前必须发起）。uuid 可空（现场生成）；callerName/callerNumber 取
 * payload 字段。cxCallUpdate 定制：displayName、分机 ^[0-9]{1,6}$ →
 * generic handle、supportsGrouping/Ungrouping=false（对齐线上 Softphone_Cx_Delegate）。
 * 登记进 pendingReports（45s 看门狗兜底撤销），INVITE 到达 matchIncoming
 * 或会话绑定时移除 */
- (NSUUID *)reportIncomingCall:(nullable NSUUID *)uuid
                    callerName:(nullable NSString *)callerName
                  callerNumber:(nullable NSString *)callerNumber;

/* INVITE 到达时匹配待关联上报（FIFO 首个号码命中 → 复用 uuid 并移除登记；
 * 未命中返回 nil，调用方现场 report） */
- (nullable NSUUID *)matchIncoming:(NSString *)remoteNumber;

/* 会话与 uuid 绑定完成（引擎在 session.callKitUuid 写入后调用；移除
 * pendingReport 登记，防 45s 看门狗误撤活跃会话） */
- (void)onSessionBound:(NSUUID *)uuid;

/* 注册 200：对仍 pending 的上报缩短撤销窗口（服务器对 push 唤醒注册
 * 1-3s 内即下发 pending INVITE，主叫提前挂断的来电不再有 INVITE——
 * 无交互场景的及时收口；弱网注册重试仍由 45s 绝对兜底覆盖） */
- (void)onRegistered;

/* 系统通话记录开关（SoftphonePreferences.includesCallKitCallsInRecent
 * 落点）：目标值与 provider 现值不一致且无活跃通话（引擎会话/pending
 * 上报/挂起动作全空）时重建 provider 生效；有活跃通话时挂起，下一通
 * report/start 入口重试——已 report 通话的记录行为本就由 report 时的
 * configuration 决定，无需打断进行中的通话 */
- (void)setCallsInRecentsEnabled:(BOOL)enabled;

#pragma mark - 事件回挂（引擎调用）

/* 引擎 200 发出后 fulfill 挂起的接听动作（防系统 UI 先行显示接通而媒体未立；
 * uuid = session.callKitUuid，引擎在 sendAnswer 成功点回调） */
- (void)onAnswerSentForUuid:(NSUUID *)uuid;

/* 接听链失败（SRD/SLD 失败或保护性 486）：fail 挂起动作（终态上报由
 * sessionEnded 驱动，此处只收动作） */
- (void)onAnswerFailedForUuid:(NSUUID *)uuid;

/* 会话终态：映射 CXCallEndedReason 后 reportCallEnded（uuid 取
 * session.callKitUuid，无则忽略） */
- (void)sessionEnded:(SipCallSession *)session;

/*
 * end action 登记后引擎侧会话已不存在（登记与查找的派发间隙终结）：
 * sessionEnded 无从消费该登记，此处清除防泄漏
 */
- (void)onEngineEndNoSessionForUuid:(NSUUID *)uuid;

#pragma mark - 去电（RN callMake / 系统记录回拨统一入口）

/* 去电发起：生成 uuid，CXStartCallAction fulfill 后回调 onActionFulfilled
 * （引擎呼出，uuid 写入会话）。系统 8s 未回调 action → 直呼兜底（保通话
 * 可用性优先）。requestId 仅透传日志 */
- (void)startCall:(NSString *)number
        requestId:(nullable NSString *)requestId
    makeCallBlock:(void (^)(NSUUID *uuid))onActionFulfilled;

@end

NS_ASSUME_NONNULL_END

#endif /* SIP_CALLKIT_COORDINATOR_H */
