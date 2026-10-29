#ifndef SIP_NETWORK_MONITOR_H_
#define SIP_NETWORK_MONITOR_H_

/*
 * SipNetworkMonitor — 换网检测（网络切换恢复链的检测端，
 * 10-20-ios-call-continuity；规格对齐安卓 NetworkMonitor.java）。
 *
 * 三分支换网判定（与安卓/RN useNetworkRestoreSync 双端语义一致）：
 *   - lost-recovered：全部断网后恢复（断网窗口 TCP 已死，IP 同样必触发）
 *   - type-switch   ：WiFi <-> 蜂窝无缝切换（旧网未失联新网先就绪）
 *   - ip-changed    ：WiFi -> WiFi 本地 IP 变化（不同 AP；同 IP 换 SSID
 *                     不触发）
 *
 * 防抖：候选 path 更新进入 STABLE_DELAY_MS 静默窗，窗口内新事件仅刷新
 * 计时——切换中间态与双网竞态（WiFi/蜂窝反复摇摆）合并为一次上报。
 *
 * 上报口径：当前活跃网络 "type|ipv4"（networkKey）与上次成功上报的
 * key 不同才触发；无可用网络清基线（恢复必触发）。
 *
 * iOS 数据源（对安卓 NetworkCallback 的差异，规格等效）：
 * NWPathMonitor 单一 pathUpdateHandler（不区分 onAvailable/onLost/
 * onLinkPropertiesChanged 三个事件，path 快照即结果）——防抖后以 key
 * 对比判定，三分支语义由 key 差异承载；无网 = path.status !=
 * satisfied 清基线；类型按 path.usesInterfaceType（wifi/cellular，其余
 * 归 other——VPN 同样触发，恢复幂等）；IPv4 取活跃接口名（en0 /
 * pdp_ip0 族）的 getifaddrs v4 地址。ObjC 侧 NWPathMonitor 类不可见
 * （Swift 专属），用等价 nw_path_monitor C 接口（iOS 12+，同引擎
 * quality monitor 形态）。
 *
 * 线程：monitor 队列 = 主队列（handler 直接收敛主线程），防抖与判定
 * 全部主线程执行（引擎线程纪律：会话操作仅主线程）；listener 在主线程
 * 回调。全部状态仅主线程读写。
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SipNetworkMonitor : NSObject

/*
 * 当前活跃网络的 IPv4（path 快照缓存，主线程读；无 v4 / 无网为 nil）。
 * 消费方：引擎 SDP 候选过滤（filterSdpCandidates）——iOS WebRTC 全接口
 * 采集 host 候选（en0/awdl 链路本地/蜂窝），SDP 层收敛到活跃接口单
 * 候选，对齐安卓"仅默认网络采集"的平台行为。
 */
@property (nonatomic, copy, nullable, readonly) NSString *activeIpv4;

/*
 * 换网事件落点（已防抖、key 已变化）；reason 见三分支。
 * 主线程回调。
 */
- (instancetype)initWithListener:(void (^)(NSString *reason))listener;

/* 开始监听。以当前网络为基线（基线变化才上报，启动不误触发）。主线程。 */
- (void)start;

/* 停止监听（注销 monitor + 取消防抖计时）。主线程。 */
- (void)stop;

/*
 * App 回前台补判定（挂起期 NWPathMonitor 事件不送达的 iOS 特有缺口，
 * F6/E13）：强制刷新当前 path 快照后直接走判定体——不经防抖窗（回前台
 * 是一次性补判，无连发合并需求）。主线程。
 */
- (void)checkNowOnForeground;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* SIP_NETWORK_MONITOR_H_ */
