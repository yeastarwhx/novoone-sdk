#ifndef SIP_CALL_SESSION_REGISTRY_H_
#define SIP_CALL_SESSION_REGISTRY_H_

/*
 * SipCallSessionRegistry — 通话会话注册表（对齐安卓 CallSessionRegistry）。
 *
 * - 并发上限 MAX_SESSIONS（2），终态会话不计容量（仅短暂留存供 UI
 *   展示终态，到 finalizeRemoveAt 由 purgeExpired 移除）；
 * - 键为会话内部 sessionId（呼出会话在 INVITE 提交前尚无 pjsua callId，
 *   callId 为 -1，故不能作键）；callId 检索经 findByCallId，该窗口期
 *   经 findByGroupId（groupId 创建即赋且稳定）定位；
 * - 线程模型：写路径仅引擎主线程；公开方法加锁以支持 snapshot
 *   "任意时刻可查"契约（跨线程读取容器安全，会话字段仍以主线程
 *   写入为准，读到的可能是近似值 —— 视图快照语义足够）。
 */

#import <Foundation/Foundation.h>

#import "SipCallSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface SipCallSessionRegistry : NSObject

/* 最大并发通话数（超出创建失败；JS 拨号前已有拦截，此处双保险） */
@property (nonatomic, class, readonly, assign) NSInteger maxSessions;

/* 终态会话在 callList 中的滞留时长（毫秒） */
@property (nonatomic, class, readonly, assign) long long terminalLingerMs;

/* 创建会话；活动会话满（>= maxSessions 且未终态）返回 nil */
- (nullable SipCallSession *)createSessionWithDirection:(SipCallDirection)direction;

/* 按 sessionId 取会话（引擎内部用） */
- (nullable SipCallSession *)sessionWithId:(long long)sessionId;

/* 按 pjsua callId 检索（callId 无效/-1 时返回 nil） */
- (nullable SipCallSession *)findByCallId:(NSInteger)callId;

/* 按 groupId 检索（呼出 INVITE 提交前 callId=-1 窗口期的定位键；
 * 对齐安卓 snapshot().firstOrNull { groupId } 扫描。终态滞留会话
 * 同样命中，调用方按需过滤） */
- (nullable SipCallSession *)findByGroupId:(NSString *)groupId;

/* 移除会话（引擎已确保 PeerConnection 等资源先行释放） */
- (nullable SipCallSession *)removeSessionWithId:(long long)sessionId;

/* 全部会话（含终态滞留）快照：插入序副本，任意时刻可查 */
- (NSArray<SipCallSession *> *)snapshot;

/* 会话总数（含终态滞留） */
- (NSInteger)count;

/* 活动会话数（未终态，容量判定用） */
- (NSInteger)activeCount;

/* 清空（shutdown 用，引擎已先行释放各会话资源） */
- (void)clear;

/* 标记终态滞留到点：到 finalizeRemoveAt 的会话移除出 callList */
- (void)purgeExpiredNow;

@end

NS_ASSUME_NONNULL_END

#endif /* SIP_CALL_SESSION_REGISTRY_H_ */
