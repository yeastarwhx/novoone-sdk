#ifndef SIP_WEBRTC_ENGINE_H_
#define SIP_WEBRTC_ENGINE_H_

/*
 * SipWebrtcEngine — SipCore 门面单例（= 安卓 SipWebrtcEngine.java 的 iOS 版）。
 *
 * 职责：pjsua 生命周期（经 ys_* C 封装）+ WebRTC PeerConnection 工厂 +
 * 多通话注册表 + 视图状态映射。对外只暴露纯 ObjC 接口（Swift 桥接层
 * 实现回调协议，无 C++ 感知）。
 *
 * 线程纪律（红线）：ys 回调来自 pjsua worker 线程，WebRTC 回调来自
 * 其内部线程——引擎内部一律 dispatch_async(main) 收敛后才动
 * registry/回调。native 入口期望主线程调用（void 方法在非主线程调用
 * 时自动转投主线程执行）。
 */

#import <Foundation/Foundation.h>

#import "SipEngineCallback.h"

NS_ASSUME_NONNULL_BEGIN

/* SIP 传输（对齐 ys_set_sip_transport；按服务器 advancedSettings.appTransport
 * 配置，非法/缺省回退 TCP——对齐安卓 normalizeTransport；TLS 已随
 * 新库（PJ_HAS_SSL_SOCK=1）交付，直通 */
typedef NS_ENUM(NSInteger, SipTransportType) {
    SipTransportUDP = 0,
    SipTransportTCP = 1,
    SipTransportTLS = 2,
};

/* accountRegister 参数键（NSDictionary 契约；缺失键用空值/默认值） */
FOUNDATION_EXPORT NSString * const SipAccountParamServer;      /* 服务器/域 host[:port] */
FOUNDATION_EXPORT NSString * const SipAccountParamUser;        /* 分机号（SIP 账号） */
FOUNDATION_EXPORT NSString * const SipAccountParamPassword;    /* 密码 */
FOUNDATION_EXPORT NSString * const SipAccountParamProxy;       /* Outbound Proxy，可选 */
FOUNDATION_EXPORT NSString * const SipAccountParamAuthUser;    /* 独立认证用户名，可选 */
FOUNDATION_EXPORT NSString * const SipAccountParamDisplayName; /* From 显示名，可选 */
FOUNDATION_EXPORT NSString * const SipAccountParamExpires;     /* 注册时效秒，<=0 库默认 */

/* 注册 200 通知（push 唤醒链撤头事件驱动用）：注册成功（含重试后成功）
 * 在主线程 post，无 userInfo——仅时序信号，监听方自带唤醒态 guard */
FOUNDATION_EXPORT NSString * const SipWebrtcEngineDidRegisterOKNotification;

/* 音频路由契约值（RN AudioRoute 枚举，src/shared/native/calling/types.ts：
 * 1=Receiver 2=Speaker 3=BluetoothSCO 4=BluetoothA2DP 5=Headset）。
 * 导出供桥接层（NovoEventHandler 的 audioExternal 判定）与引擎同源引用，
 * 避免 RN 契约值在 iOS 内出现两份定义各自漂移 */
FOUNDATION_EXPORT NSInteger const SipAudioRouteReceiver;      /* 1 听筒 */
FOUNDATION_EXPORT NSInteger const SipAudioRouteSpeaker;       /* 2 扬声器 */
FOUNDATION_EXPORT NSInteger const SipAudioRouteBluetoothSCO;  /* 3 蓝牙 SCO */
FOUNDATION_EXPORT NSInteger const SipAudioRouteBluetoothA2DP; /* 4 蓝牙 A2DP */
FOUNDATION_EXPORT NSInteger const SipAudioRouteHeadset;       /* 5 耳机 */

/* ys_pjsip_inv_state（对齐 ys_pjsua_app.h，0..6） */
typedef NS_ENUM(NSInteger, SipCallPjsuaState) {
    SipPjsuaStateNull         = 0,   /* Before INVITE is sent or received */
    SipPjsuaStateCalling      = 1,   /* After INVITE is sent */
    SipPjsuaStateIncoming     = 2,   /* After INVITE is received */
    SipPjsuaStateEarly        = 3,   /* After response with To tag */
    SipPjsuaStateConnecting   = 4,   /* After 2xx is sent/received */
    SipPjsuaStateConfirmed    = 5,   /* After ACK is sent/received */
    SipPjsuaStateDisconnected = 6,   /* Session is terminated */
};

@interface SipWebrtcEngine : NSObject

/* 门面单例 */
+ (instancetype)shared;

/* ---------------- 生命周期 ---------------- */

/*
 * 初始化 pjsua + WebRTC factory（账号注册另走 accountRegister）。
 * 顺序固定：ensureWebRtc → ys_set_sip_transport → ys_set_user_agent
 * → ys_init_pjsua(5060)。传输类型须在此定死（运行期换 transport 需
 * engineShutdown 后重启引擎）。主线程调用。
 *
 * @return true 初始化成功；false 失败（引擎标记不可用，登录流程不阻断）
 */
- (BOOL)engineStart:(id<SipEngineCallback>)callback transport:(SipTransportType)transport;

/*
 * transport 变更重建（对齐安卓 restartEngineAndRegister 引擎侧）：内部先
 * 关停（ys_destroy_pjsua 异步秒级），完成后按新 transport 重新 engineStart；
 * 完成回调在主线程（ok=false 时引擎不可用）。重启后账号不在册——
 * 调用方须在 completion(ok=true) 后补 accountRegister
 */
- (void)engineRestart:(id<SipEngineCallback>)callback
            transport:(SipTransportType)transport
            completion:(nullable void (^)(BOOL ok))completion;

/*
 * 关闭引擎：挂断全部通话 → 逐会话释放 PeerConnection → 清注册表 →
 * ys_destroy_pjsua（秒级耗时，后台队列执行，调用方不等待）。
 */
- (void)engineShutdown;

/* pjsua 是否已启动 */
- (BOOL)isStarted;

/* WebRTC 是否可用（false = 纯信令降级：注册/呼叫控制信令仍可用） */
- (BOOL)isWebRtcReady;

/* 当前引擎传输（未启动为初始 UDP） */
- (SipTransportType)currentTransport;

/* ---------------- 账户 ---------------- */

/*
 * 注册账号（重复调用先注销旧账号再注册——凭证变更走此路径）。
 * 注册结果经 onRegisterState 回调上抛。
 */
- (void)accountRegister:(NSDictionary *)params;

/* 注销并删除账号（登出） */
- (void)accountUnregister;

/*
 * 刷新注册（重发 REGISTER，不删账号、不影响进行中的通话）。
 * 推送唤醒场景账号在册时使用——删号重建会强制拆除正在振铃的通话。
 */
- (void)accountReregister;

/* REGISTER 附加自定义头（粘性：随之后的每次注册发出直到清除） */
- (void)setRegisterHeaders:(nullable NSString *)headers;

/*
 * 注入 User-Agent 设备段（推送路由关联）：须在 engineStart 前调用，
 * 注入后 buildUserAgent 优先采用、不再取 IDFV。取值必须与 PushReporter
 * 上报的 userAgentId 同源（App 侧传 DeviceInfoBridgeSwift.getDeviceId()）：
 * 服务器按「REGISTER UA 设备段 ↔ 上报 userAgentId」关联推送下发目标
 * （安卓两端同为 ANDROID_ID 同源，故推送可达；iOS 默认 IDFV 与上报值
 * 不一致导致呼入 VoIP 推送不下发）。传 nil
 * 恢复默认 IDFV。
 */
+ (void)setUserAgentDeviceId:(nullable NSString *)deviceId;

/* ---------------- ICE ---------------- */

/*
 * 设置 ICE STUN 服务器（服务器下发，"host[:port]" 逗号分隔；
 * 空串/空数组保持现状）。仅影响之后新建的 PeerConnection。
 */
- (void)setStunServers:(nullable NSString *)commaSeparated;

/*
 * 更新服务器下发的编解码配置（登录 codecConfig / MQTT
 * TENANT_CODEC_CONFIG_CHANGED 链路；ID 串为服务器编码体系：
 * 0=PCMU 8=PCMA 9=G722 18=G729 103=OPUS，一期支持除 G729 外
 * 四种，G729(18) 解析时静默过滤）。仅影响之后新建的 offer/answer
 * ——下次呼叫（含 re-INVITE）起按当前网络类型（wifi→codecOrder /
 * 蜂窝→codecOrder3G）选表生效，不触发在途通话重协商；nil/空串
 * 回退默认 order（103,9,0,8,18,102,3 解析后 = 全 4 支持编码）。
 * 主线程调用（非主线程自动转投）。
 */
- (void)updateCodecConfig:(nullable NSString *)wifi
                 cellular:(nullable NSString *)cellular;

/*
 * 音频路由（RN AudioRoute 契约：1=听筒 2=扬声器 3/4=蓝牙 5=耳机）。
 * iOS 语义：扬声器=Speaker override，其余=None override（恢复系统
 * 默认——听筒优先，已连接耳机/蓝牙由系统自动路由；程序化切换蓝牙
 * 输出受系统限制不做，交给系统路由选择器）。音频单元未启动的窗口
 * （呼出回铃期等）override 不改变实际输出，实现里补 defaultToSpeaker
 * 选项（重）设通话会话触发路由重算，并收回被播放器（expo-audio，
 * 录音/语音信箱/转录回显屏挂载即配置）借走的共享会话——.playback
 * 下 speaker override 直接 -50，详见 .mm 实现注释。
 */
- (BOOL)setAudioRoute:(NSInteger)route;

/*
 * 当前音频路由（契约值同上；快照组包上抛 RN 用——toggle 取反与
 * 扬声器按钮高亮都依赖该状态）。外设（蓝牙/耳机）优先于 override
 * 如实上报；无外设时按 override / currentRoute 输出口推导。
 */
- (NSInteger)currentAudioRoute;

/* ---------------- 呼叫操作 ---------------- */

/* 呼出（requestId 注入 INVITE X-Request-ID 头，一次性消费） */
- (void)callMake:(NSString *)number requestId:(nullable NSString *)requestId;

/* 接听来电（SRD → CreateAnswer → SLD → 等 ICE → 200） */
- (void)callAnswer:(NSInteger)callId;

/* 拒接来电（振铃期 486 Decline） */
- (void)callReject:(NSInteger)callId;

/* 挂断（BYE / CANCEL；呼出未提交 INVITE 的会话直接本地终结） */
- (void)callHangup:(NSInteger)callId;

/*
 * 按 groupId 挂断（呼出 gather 窗口期专用入口）。INVITE 提交前会话
 * callId=-1，callHangup 的 findByCallId 无法定位——桥接层在解析出的
 * callId<0 时按 RN entry.groupId 转入此口。命中未终态会话即终结：
 * callId<0（无 pjsua 会话）本地终结（撤 PeerConnection/看门狗，不发
 * 信令）；callId 已被并发看门狗提交（>=0）时先发 BYE/CANCEL 再终结。
 */
- (void)callHangupByGroupId:(NSString *)groupId;

/* hold/resume（re-INVITE 方向协商） */
- (void)callHold:(NSInteger)callId held:(BOOL)held;

/* 静音/取消静音（audioTrack isEnabled，不发 re-INVITE） */
- (void)callMute:(NSInteger)callId muted:(BOOL)muted;

/* 盲转（SIP REFER） */
- (void)callXfer:(NSInteger)callId to:(NSString *)dest;

/* 咨询转（REFER + Replaces） */
- (void)callXferAttended:(NSInteger)callId destCallId:(NSInteger)destCallId;

/* 通话中 DTMF（RTP telephone-event，RFC 4733；dtmfOff 契约由桥接层 no-op） */
- (void)callDtmf:(NSInteger)callId digits:(NSString *)digits;

/*
 * 通话质量统计（WebRTC getStats 解析为 JSON，契约对齐安卓
 * CallQualityData：codec/jitter/loss/rtt；无该通话/无统计时
 * valid=false）。
 */
- (void)getCallQuality:(NSInteger)callId
            completion:(void (^)(NSString * _Nullable json))completion;

/* ---------------- 快照 ---------------- */

/*
 * 全部会话快照（含终态滞留，getActiveCalls 契约：任意时刻可查）。
 * 字典键见 SipCallSession.h 的 SipSessionKey* 常量。
 */
- (NSArray<NSDictionary *> *)snapshotCalls;

/* ---------------- CallKit 协作面（二阶段新增） ---------------- */

/*
 * 账号是否在册（推送唤醒门面判定：在册 → accountReregister；否则冷启动
 * 快照注册）。主线程调用（_accId 仅引擎主线程读写）。
 */
- (BOOL)hasRegisteredAccount;

/*
 * 来电上报门面（PushKit didReceiveIncomingPushWith 红线路径）：
 * AppDelegate 同步调用，reportNewIncomingCall 发起后才允许 push 回调
 * 返回。coordinator 异常未就绪时返回 nil（来电回退 RN 弹屏，单点异常
 * 容错——非模式开关，开关已随双路径一并移除）。主线程调用。
 */
- (nullable NSUUID *)reportIncomingCall:(nullable NSUUID *)uuid
                             callerName:(nullable NSString *)callerName
                           callerNumber:(nullable NSString *)callerNumber;

/*
 * 去电统一入口：CallKit 模式经 CXStartCallAction（action fulfill 后引擎
 * 呼出，8s 未回调直呼兜底）；coordinator 异常未就绪时直呼（单点容
 * 错，等价一阶段 callMake 路径）。
 * RN callMake 与 SceneDelegate 通话记录回拨均经此。主线程调用。
 */
- (void)startOutgoingCall:(NSString *)number requestId:(nullable NSString *)requestId;

/* ---- 以下为 coordinator 动作落点（引擎主线程；桥接层勿直接调用） ---- */

/* 呼出并绑定 CallKit uuid（coordinator action fulfill / 系统记录回拨路径） */
- (void)callMake:(NSString *)number
       requestId:(nullable NSString *)requestId
    callKitUuid:(nullable NSUUID *)uuid;

/* uuid → 当前会话 callId（未绑定或已移除返回 -1；coordinator 动作路由用） */
- (NSInteger)callIdForCallKitUuid:(NSUUID *)uuid;

/* CallKit 终结动作分流：来电振铃中 → 486 拒接；通话中/呼出 → BYE/CANCEL */
- (void)callEndFromCallKit:(NSInteger)callId uuid:(nullable NSUUID *)uuid;

/* CallKit 事件上抛（onCallKitEvent → RN NativeCall:CallKitAction） */
- (void)notifyCallKitEvent:(NSDictionary *)event;

/* 音频会话激活线（CXProviderDelegate didActivate/didDeactivate 转发；
 * useManualAudio=YES 模式下音频单元启停唯一驱动源——注意来源是
 * CXProviderDelegate 而非 RTCAudioSessionDelegate） */
- (void)onCallKitAudioSessionActivated;
- (void)onCallKitAudioSessionDeactivated;

/* reportNewIncomingCall 失败回挂（coordinator report completion 错误分支）：
 * 解绑会话 uuid，未接听来电重新进入 RN 快照（snapshotCalls 过滤按 uuid
 * 绑定判定）——来电屏回退一阶段 RN 弹屏兜底（detail-design 4.3.4） */
- (void)onCallKitReportFailedForUuid:(NSUUID *)uuid;

/*
 * 回前台补网络判定（F6 网络切换通话连续性）：挂起期间 NWPathMonitor
 * 事件不送达（iOS 特有缺口），SceneDelegate sceneWillEnterForeground
 * 调此补一次 networkKey 判定——网络已变则走恢复编排。判定/防抖收敛在
 * SipNetworkMonitor 单点（与主链共用，恢复幂等）；挂起期 pjsua 线程
 * 同样冻结，补触发时序安全。主线程调用。
 */
- (void)checkNetworkOnForeground;

/* 外部模块诊断日志入口（App 层关键链路日志，统一进 SipCoreLogger） */
- (void)logExternal:(NSString *)message;

@end

NS_ASSUME_NONNULL_END

#endif /* SIP_WEBRTC_ENGINE_H_ */
