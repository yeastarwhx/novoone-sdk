#ifndef SIP_ENGINE_CALLBACK_H_
#define SIP_ENGINE_CALLBACK_H_

/*
 * SipEngineCallback — 引擎对外回调协议（对齐安卓 EngineCallback 4 方法）。
 * 由 Swift 桥接层实现（NovoEventHandler）。
 *
 * 线程契约（红线）：全部回调均在主线程触发——引擎内部已收敛
 * （ys 回调来自 pjsua worker 线程、WebRTC 回调来自其内部线程，
 * 均先 dispatch_async(main)）。实现方不得在回调里直接阻塞或做耗时操作。
 */

#import <Foundation/Foundation.h>

@protocol SipEngineCallback <NSObject>

/**
 * 任意会话状态/字段变化（pjsua 状态、视图状态、hold/mute、头缓存等）。
 * 上层据此拉取快照（snapshotCalls 组 NativeCall 事件全量上抛）。
 * session 字段键见 SipCallSession.h 的 SipSessionKey* 常量。
 */
- (void)onCallSessionChanged:(NSDictionary *)session;

/**
 * 注册状态变化：status 为 SIP 状态码（200 成功），text 为状态文本。
 */
- (void)onRegisterState:(int)status text:(NSString *)text;

/**
 * 新来电（INVITE 到达，offer 与头已缓存，视图状态 IncomingTrying）。
 * 上层负责展示仲裁与铃声控制，接听/拒接经 callAnswer/callReject 发起。
 */
- (void)onIncomingCall:(NSDictionary *)session;

/**
 * 引擎日志：level 对齐 pjsua（1=ERROR..5=TRACE）。pjsua 原始全量日志
 * 已进 SipCoreLogger 管道，此处只上抛引擎关键日志。
 */
- (void)onLog:(int)level message:(NSString *)msg;

/**
 * CallKit 动作状态事件（二阶段新增）：action=startCall（系统通话记录
 * 回拨，RN 拉起去电 UI）等。键为 action/source/uuid/remoteNumber。
 * CallKit 关闭时不触发。桥接层（NovoEventHandler）同步实现。
 */
- (void)onCallKitEvent:(NSDictionary *)event;

@end

#endif /* SIP_ENGINE_CALLBACK_H_ */
