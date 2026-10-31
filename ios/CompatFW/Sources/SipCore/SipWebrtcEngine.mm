#import "SipWebrtcEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#import <Network/Network.h>
#import <string.h>

#import <WebRTC/RTCAudioSession.h>
#import <WebRTC/RTCAudioSource.h>
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCConfiguration.h>
#import <WebRTC/RTCDtmfSender.h>
#import <WebRTC/RTCIceServer.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaStreamTrack.h>
#import <WebRTC/RTCPeerConnection.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCRtpCapabilities.h>
#import <WebRTC/RTCRtpCodecCapability.h>
#import <WebRTC/RTCRtpSender.h>
#import <WebRTC/RTCRtpTransceiver.h>
#import <WebRTC/RTCSessionDescription.h>
#import <WebRTC/RTCStatisticsReport.h>

#import "SipCallKitCoordinator.h"
#import "SipCallSession.h"
#import "SipCallSessionRegistry.h"
#import "SipCoreLogger.h"
#import "SipNetworkMonitor.h"
#import "SipRingtoneHelper.h"
#import "ys_pjsua_app.h"

/*
 * =====================================================================
 * 常量（对齐安卓 SipWebrtcEngine / detail-design §1.1）
 * =====================================================================
 */

/* 本地 SIP 端口（仅 UDP 绑定语义；TCP 走随机端口，见 ys_init_pjsua） */
static int const kSipLocalPort = 5060;

/* User-Agent：Mobile/126.9.1-iOS-{设备标识}，对齐旧栈格式、保留 Mobile
 * 前缀（推送配对等多个既有链路的核心标记，不得改动——改 MobileRTC 曾
 * 致推送配对失效，已实证撤销）。
 * 自研 SDK 识别约定：SDK 版本 126.9.1 为独立定义的版本
 * 序列（与 RN 工程 version / 安卓 versionName 同值，非 app 版本 26.x
 * 推导），服务器按「UA 版本首位 >= 100」识别自研 WebRTC 栈并对其强制
 * DTLS（呼入 INVITE 下发带 ICE/DTLS 的 offer）；旧栈版本首位为年份
 * 两位数（26/27…99），永不 >= 100，新旧判定无歧义。
 * 设备标识：优先取 setUserAgentDeviceId: 注入值（App 侧传
 * DeviceInfoBridgeSwift.getDeviceId()，与 PushReporter 上报的 userAgentId
 * 同源——服务器按「REGISTER UA 设备段 ↔ 上报 userAgentId」关联推送下发
 * 目标；安卓两端同为 ANDROID_ID 同源故推送可达，iOS 默认 IDFV 与上报值
 * 不一致会致杀进程呼入 VoIP 推送零到达，
 * 详见 .h setUserAgentDeviceId: 注释）；未注入回退 IDFV，再取不到
 * 回退 unknown */
static NSString * const kSipUaPrefix          = @"Mobile";
static NSString * const kSipUaVersion         = @"126.9.1";
static NSString * const kSipUaUnknownDeviceId = @"unknown";
/* setUserAgentDeviceId: 注入值（nil = 未注入走 IDFV；仅引擎启动前设置，
 * buildUserAgent 只读，无并发写） */
static NSString * sUserAgentDeviceId = nil;

/* ICE STUN 服务器缺省兜底（服务器 basic-info stunAddresses 下发前）。
 * F4 候选极简化（对齐安卓上线实现）：rtpengine（ICE-lite）按
 * 收包源地址回包（prflx 学习），host 候选直发 check 即可达，srflx 在
 * 对称 NAT 下本就无效——STUN 配置链（下发/解析/存储）保留但不再进
 * RTCConfiguration，见 setupPeerConnection 注释 */
static NSString * const kSipDefaultStunServer = @"stun:stun.cloudflare.com:3478";
static NSString * const kSipStunUrlScheme     = @"stun:";

/* ---------------- 编解码配置（10-24 webrtc-codec-config，对齐安卓） ----------------
 *
 * 服务器编码体系（Acrobits 惯例数字 ID）：0=PCMU 8=PCMA 9=G722
 * 18=G729 103=OPUS。客户端一期支持 PCMU/PCMA/G722/OPUS 四种，
 * G729(18) 二期支持——解析配置时静默过滤（SipCodecMimeForId 返回
 * nil 即忽略）；GSM=3/ILBC=102 等其余 ID 一并忽略 */

/* 默认 codec order（服务器侧惯例全集；解析只认 4 种支持编码，
 * 18/102/3 静默过滤 → 等效全 4 支持编码） */
static NSString * const kCodecDefaultOrder = @"103,9,0,8,18,102,3";

/* 主叫空交集兜底（该网络段只配了 G729 等不支持编码）：带全部 4 个
 * 支持编码，顺序 OPUS,G722,PCMU,PCMA，不失败 */
static int const kCodecFallbackOrder[] = {103, 9, 0, 8};
static int const kCodecFallbackOrderCount =
    (int)(sizeof(kCodecFallbackOrder) / sizeof(kCodecFallbackOrder[0]));

/* 配置 ID → 引擎 audio capability 的 mimeType（匹配用忽略大小写比较，
 * WebRTC 的 G711 表示为 audio/PCMU / audio/PCMA） */
static NSString * SipCodecMimeForId(int codecId)
{
    switch (codecId) {
        case 103: return @"audio/opus";
        case 9:   return @"audio/G722";
        case 0:   return @"audio/PCMU";
        case 8:   return @"audio/PCMA";
        default:  return nil;
    }
}

/* ID → 编码短名（日志与 offer 交集判定用，大写） */
static NSString * SipCodecNameForId(int codecId)
{
    NSString *mime = SipCodecMimeForId(codecId);
    if (mime == nil) {
        return [NSString stringWithFormat:@"%d", codecId];
    }
    NSRange slash = [mime rangeOfString:@"/"];
    return [[mime substringFromIndex:NSMaxRange(slash)] uppercaseString];
}

/* ID 列表 → 逗号分隔短名（日志用） */
static NSString * SipCodecNamesOfIds(NSArray<NSNumber *> *codecIds)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSNumber *idNum in codecIds) {
        [names addObject:SipCodecNameForId(idNum.intValue)];
    }
    return [names componentsJoinedByString:@","];
}

/* 配置 ID 串 → 支持编码 ID 列表（顺序=配置顺序；18/102/3 等静默
 * 过滤、重复去重；坏 token 忽略——对齐安卓 NumberFormatException
 * 分支：非纯数字 token 跳过，防 intValue 失败值 0 误映射 PCMU） */
static NSArray<NSNumber *> * SipParseCodecOrder(NSString *order)
{
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    if (order.length == 0) {
        return ids;
    }
    NSCharacterSet *nonDigits =
        [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString *part in [order componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0
            || [trimmed rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
            continue;
        }
        int value = (int)[trimmed intValue];
        if (SipCodecMimeForId(value) != nil && ![ids containsObject:@(value)]) {
            [ids addObject:@(value)];
        }
    }
    return ids;
}

/* offer SDP 音频 m 行的 rtpmap 编码名集合（大写；行式
 * a=rtpmap:<pt> <name>/<clock>[/<channels>]，m= 段切换跟踪） */
static NSSet<NSString *> * SipAudioCodecNamesFromSdp(NSString *sdp)
{
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    if (sdp.length == 0) {
        return names;
    }
    BOOL inAudio = NO;
    for (NSString *line in [sdp componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t hasPrefix:@"m="]) {
            inAudio = [t hasPrefix:@"m=audio"];
            continue;
        }
        if (!inAudio || ![t hasPrefix:@"a=rtpmap:"]) {
            continue;
        }
        NSString *rest = [t substringFromIndex:@"a=rtpmap:".length];
        NSRange sp = [rest rangeOfString:@" "];
        if (sp.location == NSNotFound || NSMaxRange(sp) >= rest.length) {
            continue;
        }
        NSString *enc = [rest substringFromIndex:NSMaxRange(sp)];
        NSRange slash = [enc rangeOfString:@"/"];
        NSString *name = (slash.location != NSNotFound
            ? [enc substringToIndex:slash.location] : enc);
        name = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (name.length > 0) {
            [names addObject:name.uppercaseString];
        }
    }
    return names;
}

/* ICE gathering 看门狗双窗（安卓 GATHER_WATCHDOG_MS / CANDIDATE_FLUSH_MS）：
 * SLD 后先布 800ms 兜底窗（候选回调异常时带已收集候选即发）；候选每到达
 * 一个重臂 150ms 落盘窗——最后一个候选 +150ms 即发（localDescription
 * 候选并入滞后于回调的保守间隔），不等 COMPLETE。iOS 实证（10-21 真机
 * 日志）：GATHER_CONTINUALLY 下 COMPLETE 状态永不到达（安卓 ~3ms 即
 * COMPLETE 属 SDK 版本差异），发送路径必须走候选去抖窗 */
static NSTimeInterval const kSipGatherWatchdogSec = 0.8;
static NSTimeInterval const kSipCandidateFlushSec = 0.15;
/* 呼入初始应答零候选保护预算（安卓 ZERO_CANDIDATE_BUDGET_MS）：answer
 * 零 a=candidate 时不发送——预算内延长等待收集（看门狗周期重查，候选
 * 到达经正常链发送），超预算收口（已接听 hangup / 未接听 486）。依据：
 * ①零候选 200 媒体必不立（服务器非 trickle），通话"建立"即全程无声
 * 且无收口路径；②明文 TCP 下中间设备会静默丢弃零候选的 200。仅作用于
 * 呼入初始应答（INCOMING/EARLY 窗口，200 未发过；re-INVITE 应答复用
 * 已收集候选，CONFIRMED 态不触发） */
static long long const kZeroCandidateBudgetMs = 6000;

/* 网络切换恢复（10-20-ios-call-continuity，对齐安卓 1810-2032 编排）：
 * 信令恢复 5s 看门狗——SHUTDOWN_TP/COMPLETED 回调丢失（上游状态机卡在
 * 等服务器响应）时按已完成部分继续，注册由 reg watch 兜底 */
static NSTimeInterval const kNetRecoveryIpChangeTimeoutSec = 5.0;
/* 注册监督（reg watch）：35s 周期（> 32s REGISTER tsx 超时，防止与
 * ip_change 状态机重叠——上游对重叠仅告警不阻止，重叠会错乱状态机）、
 * 最多 3 次强制换连接重试（防恢复风暴） */
static NSTimeInterval const kRegWatchIntervalSec = 35.0;
static int const kRegWatchMaxAttempts = 3;
/* ys_ip_change_progress 的 step 值（pjsua_ip_change_op 枚举，pjsua.h:895：
 * NULL=0/SHUTDOWN_TP=1/.../COMPLETED=7；ys 头不依赖 pjsip 头，此处取
 * 数值常量） */
static int const kPjsuaIpChangeOpShutdownTp = 1;
static int const kPjsuaIpChangeOpCompleted  = 7;

/* DTMF 参数（RFC 4733 telephone-event；安卓 insertDtmf(200ms, 100ms)） */
static NSTimeInterval const kSipDtmfDuration    = 0.2;
static NSTimeInterval const kSipDtmfInterToneGap = 0.1;

/* SDP 时钟归一（telephone-event）：WebRTC 原生 capability 时钟 48000，
 * 服务器 rtpengine/RFC4733 按 8000——两侧各说各的时钟：呼出 offer 带
 * 48000 被 rtpengine 剥（200 OK answer 只剩 PCMU）；来电 offer 8000 与
 * 本端 capability 48000 匹配不上、answer 不带（canInsertDtmf 恒 false）。
 * 双向各翻一次时钟文本：进出 WebRTC 边界归一，
 * 编码名/PT 号不变，clockrate 仅出现在 rtpmap 行、无其他引用点 */
static NSString *SipSdpTelephoneEventToWebRTC(NSString *sdp)
{
    return [sdp stringByReplacingOccurrencesOfString:@"telephone-event/8000"
                                          withString:@"telephone-event/48000"];
}

static NSString *SipSdpTelephoneEventToWire(NSString *sdp)
{
    return [sdp stringByReplacingOccurrencesOfString:@"telephone-event/48000"
                                          withString:@"telephone-event/8000"];
}

/* 单元启动后扬声器重申延迟：didStartPlayOrRecord 重放之后再补一发双写
 * （见 applySpeakerCategoryAndOverride）——WebRTC 启动序列里自身的
 * setCategory 可能晚于重放（同值重设清 override），0.5s 后配置序列已
 * 稳定、输入活动已建立，双写即时生效 */
static NSTimeInterval const kSipSpeakerReassertSec = 0.5;

/* 注册认证域："*" 表示任意（对齐 demo/安卓注册形态） */
static NSString * const kSipAnyRealm = @"*";

/* 音频路由契约值（语义见 SipWebrtcEngine.h；iOS 仅 Speaker 需要
 * override，其余一律恢复系统默认路由） */
NSInteger const SipAudioRouteReceiver      = 1;
NSInteger const SipAudioRouteSpeaker       = 2;
NSInteger const SipAudioRouteBluetoothSCO  = 3;
NSInteger const SipAudioRouteBluetoothA2DP = 4;
NSInteger const SipAudioRouteHeadset       = 5;

NSString * const SipAccountParamServer      = @"server";
NSString * const SipAccountParamUser       = @"user";
NSString * const SipAccountParamPassword   = @"password";
NSString * const SipAccountParamProxy      = @"proxy";
NSString * const SipAccountParamAuthUser   = @"authUser";
NSString * const SipAccountParamDisplayName = @"displayName";
NSString * const SipAccountParamExpires    = @"expires";
NSString * const SipWebrtcEngineDidRegisterOKNotification
    = @"SipWebrtcEngineDidRegisterOKNotification";

/*
 * =====================================================================
 * ys_pjsua_app 回调（C 函数指针，pjsua worker 线程触发）
 *
 * 线程红线：字符串仅回调期间有效——必须在此处立即拷贝成 NSString，
 * 再 dispatch_async(main) 交给引擎处理（对齐安卓 postXxx 转主线程）。
 * =====================================================================
 */

@interface SipWebrtcEngine () <RTCAudioSessionDelegate>
/* ys 回调入口（主线程处理） */
- (void)handleRegisterState:(int)accId status:(int)status text:(NSString *)text;
- (void)handleCallState:(int)callId state:(int)state lastStatus:(int)lastStatus;
- (void)handleAnswerSdp:(NSString *)sdp callId:(int)callId;
- (void)handleIncomingSdp:(NSString *)sdp
                   callId:(int)callId
                requestId:(NSString *)requestId
             callerIdName:(NSString *)callerIdName
             remoteNumber:(NSString *)remoteNumber;
- (void)handleReinviteSdp:(NSString *)sdp callId:(int)callId;
- (void)handleTransferState:(int)callId status:(int)status isFinal:(BOOL)isFinal;
- (void)handleEngineLog:(int)level message:(NSString *)msg;
- (void)handleIpChangeProgress:(int)step status:(int)status;
/* 内部工具（实现位于本文件后段，此处前向声明供前部调用） */
- (void)ensureWebRtc;
- (void)engineShutdownOnMain;
- (void)engineLog:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)ysLog:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)webrtcLog:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)runOnMain:(void (^)(void))block;
+ (NSString *)buildUserAgent;
+ (NSString *)transportName:(SipTransportType)transport;
+ (NSString *)callStateName:(int)state;
+ (NSString *)iceConnName:(RTCIceConnectionState)state;
+ (NSString *)pcStateName:(RTCPeerConnectionState)state;
+ (BOOL)detectRemoteHold:(NSString *)sdp;
- (NSString *)filterSdpCandidates:(NSString *)sdp;
- (void)cancelGatherWatchdog:(SipCallSession *)session;
- (void)armGatherWatchdog:(SipCallSession *)session;
- (void)armGatherWatchdog:(SipCallSession *)session afterSec:(NSTimeInterval)sec;
- (void)gatherWatchdogFiredForSessionId:(long long)sessionId;
- (void)closePeerConnection:(SipCallSession *)session suffix:(NSString *)suffix;
- (void)notifySessionChanged:(SipCallSession *)session;
- (void)resetAudioRouteForNewCallExcluding:(NSInteger)callId;
- (BOOL)hasEstablishedSession;
/* 网络切换恢复编排（定义见 #pragma mark 网络切换恢复段） */
- (void)handleNetworkChanged:(NSString *)reason;
/* 呼叫链内部（安卓锚点见各方法注释） */
- (void)startOutgoingCall:(SipCallSession *)session;
- (void)setupPeerConnection:(SipCallSession *)session;
- (void)answerRemoteOffer:(SipCallSession *)session offerSdp:(NSString *)offerSdp;
- (void)renegotiate:(SipCallSession *)session;
- (void)sendInviteWithLocalSdp:(SipCallSession *)session;
- (void)sendAnswerWithLocalSdp:(SipCallSession *)session;
- (void)sendReinviteWithLocalSdp:(SipCallSession *)session;
- (void)terminateSession:(SipCallSession *)session view:(NSString *)view;
- (void)onSessionTerminated:(SipCallSession *)session;
- (void)applyTrackEnabled:(SipCallSession *)session;
- (void)applyTransceiverDirection:(SipCallSession *)session held:(BOOL)held;
- (void)holdInternal:(SipCallSession *)session held:(BOOL)held;
- (NSString *)computeViewState:(SipCallSession *)session
                         state:(int)state
                    lastStatus:(int)lastStatus;
- (void)handleViewSideEffects:(SipCallSession *)session view:(NSString *)view;
- (SipCallSession *)sessionForPeerConnection:(RTCPeerConnection *)pc;
- (NSString *)qualityJsonWithReport:(RTCStatisticsReport *)report;
- (NSString *)currentNetworkName;
/* 编解码选表与偏好应用（定义见 #pragma mark 编解码配置段） */
- (void)applyCodecPreferencesForOffer:(SipCallSession *)session;
- (void)applyCodecPreferencesForAnswer:(SipCallSession *)session
                              offerSdp:(NSString *)offerSdp;
- (void)applyCodecPreferences:(RTCPeerConnection *)pc
                     codecIds:(NSArray<NSNumber *> *)codecIds
                        phase:(NSString *)phase
                      network:(NSString *)network;
- (NSString *)effectiveCodecOrder;
@end

static void ys_engine_on_register_state(pjsua_acc_id acc_id, int status, const char *text)
{
    NSString *textCopy = (text != NULL) ? [NSString stringWithUTF8String:text] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleRegisterState:acc_id status:status text:textCopy];
    });
}

static void ys_engine_on_call_state(pjsua_call_id call_id, int state, int last_status)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleCallState:call_id state:state lastStatus:last_status];
    });
}

static void ys_engine_on_answer_sdp(pjsua_call_id call_id, const char *sdp)
{
    NSString *sdpCopy = (sdp != NULL) ? [NSString stringWithUTF8String:sdp] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleAnswerSdp:sdpCopy callId:call_id];
    });
}

static void ys_engine_on_incoming_sdp(pjsua_call_id call_id, const char *sdp,
                                      const char *request_id, const char *caller_id_name,
                                      const char *remote_number)
{
    /* 头/号码与 sdp 同生命周期：仅回调期间有效，此处拷贝 */
    NSString *sdpCopy = (sdp != NULL) ? [NSString stringWithUTF8String:sdp] : @"";
    NSString *requestIdCopy = (request_id != NULL) ? [NSString stringWithUTF8String:request_id] : nil;
    NSString *callerIdNameCopy = (caller_id_name != NULL) ? [NSString stringWithUTF8String:caller_id_name] : nil;
    NSString *remoteNumberCopy = (remote_number != NULL) ? [NSString stringWithUTF8String:remote_number] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleIncomingSdp:sdpCopy
                                              callId:call_id
                                           requestId:requestIdCopy
                                        callerIdName:callerIdNameCopy
                                        remoteNumber:remoteNumberCopy];
    });
}

static void ys_engine_on_reinvite_sdp(pjsua_call_id call_id, const char *sdp)
{
    NSString *sdpCopy = (sdp != NULL) ? [NSString stringWithUTF8String:sdp] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleReinviteSdp:sdpCopy callId:call_id];
    });
}

static void ys_engine_on_transfer_state(pjsua_call_id call_id, int status, int is_final)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleTransferState:call_id status:status
                                              isFinal:(is_final != 0)];
    });
}

static void ys_engine_on_log(int level, const char *msg)
{
    if (msg == NULL || msg[0] == '\0') {
        return;
    }
    /* pjsua 全量日志进 SipCoreLogger 管道（os_log + Sip.log 文件，
     * SipCoreLogger 线程安全，无需切线程）；level<=3 的关键日志
     * 才上抛引擎回调（level 4 为 SIP 报文 dump，量过大） */
    NSString *line = [NSString stringWithUTF8String:msg];
    if (line == nil) {
        return;
    }
    [SipCoreLogger pjsuaLog:level message:line];
    if (level <= (int)SipLogLevelInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[SipWebrtcEngine shared] handleEngineLog:level message:line];
        });
    }
}

/* ys_ip_change_progress（pjsua worker 线程触发）→ 主线程：库层网络
 * 切换信令恢复状态机进度（SHUTDOWN_TP/COMPLETED 等步），编排见
 * #pragma mark 网络切换恢复段 */
static void ys_engine_on_ip_change_progress(int step, int status)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SipWebrtcEngine shared] handleIpChangeProgress:step status:status];
    });
}

/* ys_acc_registerinfo 字符串填充（NSString → 定长 char[]，截断安全） */
static void ys_fill_field(char *dst, size_t size, NSString *value)
{
    if (size == 0) {
        return;
    }
    if (value.length == 0) {
        dst[0] = '\0';
        return;
    }
    strlcpy(dst, value.UTF8String ?: "", size);
}

/*
 * =====================================================================
 * 引擎实现
 * =====================================================================
 */

@interface SipWebrtcEngine () <RTCPeerConnectionDelegate>
/* 会话注册表（引擎级唯一，多通话核心容器） */
@property (nonatomic, strong) SipCallSessionRegistry *registry;
/* WebRTC 工厂（engineStart 的 ensureWebRtc 创建，shutdown 释放） */
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
/* WebRTC 初始化失败时降级为纯信令模式：pjsua 注册/呼叫控制仍可用，
 * 媒体不可用并逐次记日志 */
@property (nonatomic, assign) BOOL webrtcFailed;
/* pjsua 生命周期 / 账号 */
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) pjsua_acc_id accId;
@property (nonatomic, assign) SipTransportType transport;
@property (nonatomic, copy, nullable) NSString *lastRegText;
@property (nonatomic, weak, nullable) id<SipEngineCallback> callback;
/* ICE STUN 服务器（服务器下发经 setStunServers 覆盖。F4 候选极简化后
 * 仅存储不消费——setupPeerConnection 固定空 iceServers，配置链保留
 * （接口契约不变，服务器下发链零感知）。命名避开公开方法
 * setStunServers: 的合成存取器冲突） */
@property (nonatomic, copy) NSArray<RTCIceServer *> *iceServers;
/* 服务器下发 codec order（ID 串如 "103,0"；nil/空 = 未下发按默认
 * order，见 kCodecDefaultOrder）。updateCodecConfig 经 runOnMain 写、
 * 选表在引擎主线程读（线程纪律内，无跨线程并发） */
@property (nonatomic, copy, nullable) NSString *codecOrderWifi;
@property (nonatomic, copy, nullable) NSString *codecOrderCellular;
/* pjsua 销毁队列（ys_destroy_pjsua 秒级耗时，不占用主线程） */
@property (nonatomic, strong) dispatch_queue_t shutdownQueue;
/* Speaker override 当前是否生效（setAudioRoute 写入；currentAudioRoute
 * 推导用。AVAudioSession 不暴露 override 查询口，须自行跟踪。audio unit
 * 启动被清时由 audioSessionDidStartPlayOrRecord 按本标志重放） */
@property (nonatomic, assign) BOOL speakerOverride;
/* RTCAudioSession delegate 是否已挂（addDelegate 弱持有但无去重保证，
 * shutdown→restart 会重跑 ensureWebRtc，用标志保证进程内仅注册一次） */
@property (nonatomic, assign) BOOL audioSessionDelegateAdded;
/* 网络类型监视（getCallQuality 的 network 字段，安卓 networkTypeName 对应）。
 * NWPathMonitor 为 Swift 专属类（ObjC 头仅有 C API），此处用等价
 * nw_path_monitor C 接口（OS_OBJECT 风格对象，ARC 可持有，iOS 12+） */
@property (nonatomic, strong, nullable) nw_path_monitor_t networkMonitor;
@property (nonatomic, copy) NSString *networkName;
/* CallKit 协作模块（init 时创建——冷启动推送先于 engineStart 到达时
 * reportNewIncomingCall 仍可用）。弱引用引擎，
 * 动作全部落回本引擎方法执行 */
@property (nonatomic, strong, nullable) SipCallKitCoordinator *callKitCoordinator;
/* 接通 5s 音频兜底看门狗（answerSent/CONFIRMED arm，didActivate 撤） */
@property (nonatomic, strong, nullable) NSTimer *audioForceWatchdog;
/* 5s 兜底 arm 时记录会话 sessionId（fire 时校验仍处通话中） */
@property (nonatomic, assign) long long audioForceSessionId;
/* ---------------- 网络切换恢复（10-20，仅主线程读写） ---------------- */
/* 换网检测器（NWPathMonitor 三分支判定 + 800ms 防抖，见
 * SipNetworkMonitor.h；engineStart 成功后 start / shutdown 前 stop） */
@property (nonatomic, strong, nullable) SipNetworkMonitor *netMonitor;
/* 恢复周期单飞标志（在途=true；新事件只标 pendingRerun，防恢复风暴） */
@property (nonatomic, assign) BOOL netRecoveryRunning;
/* 恢复周期进行中又来换网事件：本轮收尾后再走一轮（双网竞态残余） */
@property (nonatomic, assign) BOOL netRecoveryPendingRerun;
/* 本轮恢复周期起点（cycle done / ip-change done 计时用） */
@property (nonatomic, assign) long long netRecoveryStartMs;
/* 信令恢复 5s 看门狗（SHUTDOWN_TP/COMPLETED 回调丢失时按已完成部分继续） */
@property (nonatomic, strong, nullable) NSTimer *ipChangeWatchdog;
/* 注册监督（reg watch）：恢复后注册仍未 200（服务器半开连接占位）时
 * 周期强制换连接重试的状态（35s 一拍、最多 3 次） */
@property (nonatomic, assign) BOOL regWatchActive;
@property (nonatomic, assign) int regWatchAttempts;
@property (nonatomic, strong, nullable) NSTimer *regWatchTimer;
/* 最近一次 REGISTER 结果码（200 = 已注册；reg watch tick 判定用，
 * 主线程读写——handleRegisterState 即主线程） */
@property (nonatomic, assign) int lastRegStatus;
/* [webrtc] gather complete 计时：sessionId → gathering 窗口起点毫秒。
 * arm 时仅在无记录时写入（didGenerateIceCandidate 重挂看门狗不重置
 * 起点）；COMPLETE 点读出打日志后清除（看门狗到点/会话释放同清） */
@property (nonatomic, strong, nullable) NSMutableDictionary<NSNumber *, NSNumber *> *gatherStartTimes;
/* 呼入初始应答零候选保护计时（安卓 zeroCandidateSince）：sessionId →
 * 首次检出零候选的毫秒时刻；发送成功/超预算收口/会话释放时清除 */
@property (nonatomic, strong, nullable) NSMutableDictionary<NSNumber *, NSNumber *> *zeroCandidateSinceMs;
@end

@implementation SipWebrtcEngine

#pragma mark - 单例

+ (instancetype)shared
{
    static SipWebrtcEngine *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[SipWebrtcEngine alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _registry = [[SipCallSessionRegistry alloc] init];
        _accId = -1;
        _transport = SipTransportUDP;
        _iceServers = @[[[RTCIceServer alloc] initWithURLStrings:@[kSipDefaultStunServer]]];
        _shutdownQueue = dispatch_queue_create("com.novoone.sipcore.shutdown", DISPATCH_QUEUE_SERIAL);
        _networkName = @"";
        /* CallKit：init 时创建 coordinator（而非 engineStart）——推送唤醒
         * 链路 AppDelegate 先 report 后唤醒引擎，冷启动窗口也要能弹卡 */
        _callKitCoordinator = [[SipCallKitCoordinator alloc] initWithEngine:self];
    }
    return self;
}

#pragma mark - 对外查询

- (BOOL)isStarted
{
    return _started;
}

- (BOOL)isWebRtcReady
{
    return _factory != nil && !_webrtcFailed;
}

- (SipTransportType)currentTransport
{
    return _transport;
}

- (void)logExternal:(NSString *)message
{
    [self engineLog:@"%@", message];
}

#pragma mark - 生命周期

- (BOOL)engineStart:(id<SipEngineCallback>)callback transport:(SipTransportType)transport
{
    if (_started) {
        [self engineLog:@"already started"];
        return YES;
    }
    if (transport != SipTransportUDP && transport != SipTransportTCP
        && transport != SipTransportTLS) {
        [self engineLog:@"invalid transport %ld", (long)transport];
        return NO;
    }
    _callback = callback;
    _transport = transport;

    @try {
        [self ensureWebRtc];

        /* 必须在 ys_init_pjsua 之前调用（影响 transport 创建与 proxy
         * Route 头的 ;transport= 参数） */
        if (ys_set_sip_transport((int)transport) != 0) {
            [self engineLog:@"ys_set_sip_transport failed"];
            return NO;
        }

        /* 统一 User-Agent：REGISTER/INVITE 等所有出站消息携带同一 UA */
        ys_set_user_agent([self.class buildUserAgent].UTF8String);

        ys_pjsua_callback callbacks;
        memset(&callbacks, 0, sizeof(callbacks));
        callbacks.ys_register_state    = &ys_engine_on_register_state;
        callbacks.ys_call_state        = &ys_engine_on_call_state;
        callbacks.ys_call_answer_sdp   = &ys_engine_on_answer_sdp;
        callbacks.ys_incoming_call_sdp = &ys_engine_on_incoming_sdp;
        callbacks.ys_call_reinvite_sdp = &ys_engine_on_reinvite_sdp;
        callbacks.ys_call_transfer_state = &ys_engine_on_transfer_state;
        callbacks.ys_log               = &ys_engine_on_log;
        callbacks.ys_ip_change_progress = &ys_engine_on_ip_change_progress;
        if (ys_init_pjsua(&callbacks, kSipLocalPort) != 0) {
            [self engineLog:@"ys_init_pjsua failed"];
            return NO;
        }

        _started = YES;
        /* 换网检测启动（对齐安卓接线点）：以当前网络为基线，检测到换网
         * （三分支判定 + 800ms 防抖后）走恢复编排 handleNetworkChanged:。
         * listener 主线程回调（monitor 队列 = 主队列）；引擎为进程级
         * 单例，block 强持 self 无泄漏 */
        _netMonitor = [[SipNetworkMonitor alloc] initWithListener:^(NSString *reason) {
            [self handleNetworkChanged:reason];
        }];
        [_netMonitor start];
        [self engineLog:@"pjsua started (ys layer, %@)",
            [self.class transportName:_transport]];
        return YES;
    } @catch (NSException *exception) {
        /* 工厂异常等：引擎 broken，后续所有操作失败（登录流程不阻断） */
        [self engineLog:@"init FAILED: %@ -> engine broken", exception];
        return NO;
    }
}

- (void)engineShutdown
{
    /* 线程模型红线：会话/Registry/RingtoneHelper 仅主线程可碰——
     * 调用方一律转主线程执行实际销毁；调用方不等待（销毁秒级） */
    [self runOnMain:^{
        [self engineShutdownOnMain];
    }];
}

- (void)engineShutdownOnMain
{
    if (!_started) {
        return;
    }
    _started = NO;
    ys_hangup_all_calls();
    for (SipCallSession *session in [self.registry snapshot]) {
        [self cancelGatherWatchdog:session];
        [self closePeerConnection:session suffix:@" (shutdown)"];
    }
    [self.registry clear];
    /* 释放回调引用（释放 RN delegate） */
    _callback = nil;
    [SipRingtoneHelper stopAll];
    _accId = -1;

    /* 网络监视释放（quality monitor） */
    if (self.networkMonitor != NULL) {
        nw_path_monitor_cancel(self.networkMonitor);
        self.networkMonitor = nil;
    }

    /* 换网检测与恢复编排释放（对齐安卓接线点）：stop 注销 monitor +
     * 取消防抖；reg watch 撤拍；在途恢复周期状态复位（引擎停后回调/
     * 看门狗全部失效，重启后由新一轮事件重建） */
    [self.netMonitor stop];
    self.netMonitor = nil;
    [self stopRegWatch:NO];
    [self cancelIpChangeWatchdog];
    self.netRecoveryRunning = NO;
    self.netRecoveryPendingRerun = NO;
    /* 陈旧 200 会让重启后 reg watch 误判已注册而撤拍（新引擎首个
     * REGISTER 无回调的窗口，正是 reg watch 要兜底的场景） */
    _lastRegStatus = 0;

    /* ys_destroy_pjsua 秒级耗时：后台串行队列执行，主线程立即返回；
     * 完成后回主线程释放 factory（ARC） */
    dispatch_async(self.shutdownQueue, ^{
        ys_destroy_pjsua();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.factory = nil;
        });
    });
}

- (void)engineRestart:(id<SipEngineCallback>)callback
            transport:(SipTransportType)transport
            completion:(void (^)(BOOL ok))completion
{
    /* transport 变更重建专用（对齐安卓 restartEngineAndRegister 的引擎侧）：
     * ys_destroy_pjsua 在 shutdownQueue 异步执行（秒级），必须等其完成后
     * 才能 ys_init_pjsua（否则双重初始化竞态崩溃）。shutdownQueue 串行
     * FIFO 保证顺序：[destroy（若已启动）] → 回主线程 engineStart。
     * 完成回调在主线程；重启后账号不在册，由调用方补注册 */
    [self runOnMain:^{
        if (self->_started) {
            [self engineShutdownOnMain]; /* destroy 已派入 shutdownQueue */
        }
        dispatch_async(self.shutdownQueue, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL ok = [self engineStart:callback transport:transport];
                if (!ok) {
                    [self engineLog:@"engineRestart: start FAILED"];
                }
                if (completion != nil) {
                    completion(ok);
                }
            });
        });
    }];
}

#pragma mark - WebRTC 初始化（engineStart 内调用）

- (void)ensureWebRtc
{
    if (_factory != nil || _webrtcFailed) {
        return;
    }
    @try {
        _factory = [[RTCPeerConnectionFactory alloc] init];

        /* iOS 音频会话显式配置（安卓 ADM 自动处理，iOS 必须显式）：
         * playAndRecord + voiceChat。AEC3 软件回声消除内建（安卓
         * "硬件 AEC 恒关"教训在 iOS 无对应开关，默认即软件 AEC）。
         * 会话配置失败不阻断：信令与 WebRTC 栈仍可用。 */
        NSError *error = nil;
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        BOOL ok = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                       mode:AVAudioSessionModeVoiceChat
                                    options:0
                                      error:&error];
        if (!ok) {
            [self webrtcLog:@"AVAudioSession configure FAILED: %@ (continue)",
                error.localizedDescription ?: @"unknown error"];
        } else {
            [self webrtcLog:@"audio session configured (playAndRecord / voiceChat)"];
        }

        /* CallKit 模式音频会话重构（detail 5.2 步骤 4）：音频单元启停交由
         * CXProviderDelegate didActivate/didDeactivate 驱动（引擎
         * onCallKitAudioSessionActivated/Deactivated 设 isAudioEnabled） */
        RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
        rtcSession.useManualAudio = YES;
        [self webrtcLog:@"[AUDIO] manual=YES (callkit) — audio unit 由 didActivate 驱动"];

        /* 挂 RTCAudioSession delegate：audio unit 每次初始化/启动会重设
         * category（同值也清除 port override），须在其后按 speakerOverride
         * 重放（见 audioSessionDidStartPlayOrRecord 实现） */
        if (!_audioSessionDelegateAdded) {
            _audioSessionDelegateAdded = YES;
            [[RTCAudioSession sharedInstance] addDelegate:self];
            [self webrtcLog:@"RTCAudioSession delegate attached"];
        }

        /* 网络类型监视（getCallQuality 的 network 字段：wifi/cellular/""，
         * 对齐安卓 networkTypeName；仅展示用）。C API 形态（NWPathMonitor
         * ObjC 不可见），update handler 先拷贝结果再转主线程写缓存 */
        nw_path_monitor_t monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(monitor,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
        __weak SipWebrtcEngine *weakSelf = self;
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            NSString *name = @"";
            if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) {
                name = @"wifi";
            } else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
                name = @"cellular";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.networkName = name;
            });
        });
        nw_path_monitor_start(monitor);
        self.networkMonitor = monitor;

        [self webrtcLog:@"PeerConnectionFactory ready"];
    } @catch (NSException *exception) {
        /* 降级纯信令模式（注册/呼叫控制信令仍可用） */
        _factory = nil;
        _webrtcFailed = YES;
        [self webrtcLog:@"PeerConnectionFactory init FAILED: %@ -> signaling-only mode (no media)",
            exception];
    }
}

+ (void)setUserAgentDeviceId:(NSString *)deviceId
{
    /* 须在 engineStart 前调用（382 行 ys_set_user_agent 前生效即可）；
     * nil/清空恢复默认 IDFV */
    sUserAgentDeviceId = [deviceId copy];
}

+ (NSString *)buildUserAgent
{
    /* 版本段固定 126.9.1（SDK 独立版本序列，约定见常量区注释） */
    NSString *deviceIdentifier = sUserAgentDeviceId;
    if (deviceIdentifier.length == 0) {
        deviceIdentifier = [UIDevice currentDevice].identifierForVendor.UUIDString;
    }
    if (deviceIdentifier.length == 0) {
        deviceIdentifier = kSipUaUnknownDeviceId;
    }
    return [NSString stringWithFormat:@"%@/%@-iOS-%@",
            kSipUaPrefix, kSipUaVersion, deviceIdentifier];
}

+ (NSString *)transportName:(SipTransportType)transport
{
    switch (transport) {
        case SipTransportTLS:
            return @"TLS";
        case SipTransportTCP:
            return @"TCP";
        default:
            return @"UDP";
    }
}

#pragma mark - 账户

- (void)accountRegister:(NSDictionary *)params
{
    [self runOnMain:^{
        if (!self->_started) {
            [self engineLog:@"start first"];
            return;
        }
        /* 重复注册先注销旧账号（凭证变更路径），无残留账号 */
        if (self->_accId >= 0) {
            ys_unregister_account(self->_accId);
            self->_accId = -1;
        }

        ys_acc_registerinfo regInfo;
        memset(&regInfo, 0, sizeof(regInfo));
        ys_fill_field(regInfo.reg_uri, sizeof(regInfo.reg_uri), params[SipAccountParamServer]);
        ys_fill_field(regInfo.realm, sizeof(regInfo.realm), kSipAnyRealm);
        ys_fill_field(regInfo.username, sizeof(regInfo.username), params[SipAccountParamUser]);
        ys_fill_field(regInfo.auth_username, sizeof(regInfo.auth_username), params[SipAccountParamAuthUser]);
        ys_fill_field(regInfo.registername, sizeof(regInfo.registername), params[SipAccountParamDisplayName]);
        ys_fill_field(regInfo.passwd, sizeof(regInfo.passwd), params[SipAccountParamPassword]);
        ys_fill_field(regInfo.proxy_uri, sizeof(regInfo.proxy_uri), params[SipAccountParamProxy]);
        regInfo.register_expires = (int)[params[SipAccountParamExpires] integerValue];

        self->_accId = ys_register_account(&regInfo);
        if (self->_accId < 0) {
            [self engineLog:@"ys_register_account failed"];
        } else {
            NSString *user = params[SipAccountParamUser] ?: @"";
            NSString *server = params[SipAccountParamServer] ?: @"";
            NSMutableString *detail = [NSMutableString stringWithFormat:
                                       @"registering %@ via %@", user, server];
            NSString *proxy = params[SipAccountParamProxy];
            if (proxy.length > 0) {
                [detail appendFormat:@" (proxy %@)", proxy];
            }
            NSString *authUser = params[SipAccountParamAuthUser];
            if (authUser.length > 0) {
                [detail appendFormat:@" (auth %@)", authUser];
            }
            [detail appendString:@" ..."];
            [self engineLog:@"%@", detail];
        }
    }];
}

- (void)accountUnregister
{
    [self runOnMain:^{
        if (!self->_started) {
            return;
        }
        if (self->_accId < 0) {
            return;
        }
        if (ys_unregister_account(self->_accId) == 0) {
            [self engineLog:@"account unregistered"];
            self->_accId = -1;
        } else {
            [self ysLog:@"ys_unregister_account failed"];
        }
    }];
}

- (void)accountReregister
{
    [self runOnMain:^{
        if (!self->_started) {
            return;
        }
        if (self->_accId < 0) {
            return;
        }
        if (ys_reregister_account(self->_accId) == 0) {
            [self engineLog:@"account re-REGISTER"];
        } else {
            [self ysLog:@"ys_reregister_account failed"];
        }
    }];
}

- (void)setRegisterHeaders:(NSString *)headers
{
    [self runOnMain:^{
        ys_set_register_headers(headers.length > 0 ? headers.UTF8String : NULL);
        [self engineLog:@"REGISTER headers %@",
            headers.length > 0 ? @"set (sticky until clear)" : @"cleared"];
    }];
}

#pragma mark - ICE

- (void)setStunServers:(NSString *)commaSeparated
{
    [self runOnMain:^{
        if (commaSeparated.length == 0) {
            return;
        }
        NSMutableArray<RTCIceServer *> *servers = [[NSMutableArray alloc] init];
        for (NSString *raw in [commaSeparated componentsSeparatedByString:@","]) {
            NSString *addr = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if (addr.length == 0) {
                continue;
            }
            if (![addr hasPrefix:kSipStunUrlScheme]) {
                addr = [kSipStunUrlScheme stringByAppendingString:addr];
            }
            [servers addObject:[[RTCIceServer alloc] initWithURLStrings:@[addr]]];
        }
        if (servers.count > 0) {
            self.iceServers = [servers copy];
            [self engineLog:@"STUN servers set: %@", commaSeparated];
        }
    }];
}

#pragma mark - 编解码配置

/* 语义见 SipWebrtcEngine.h。存储不解析——选表时按当前网络取表解析，
 * 配置运行时变更（MQTT 通知）下次 offer/answer 自然生效 */
- (void)updateCodecConfig:(NSString *)wifi cellular:(NSString *)cellular
{
    [self runOnMain:^{
        self.codecOrderWifi = [wifi copy];
        self.codecOrderCellular = [cellular copy];
        [self webrtcLog:@"codec config updated: wifi=%@, cellular=%@",
            wifi.length > 0 ? wifi : @"(default)",
            cellular.length > 0 ? cellular : @"(default)"];
    }];
}

/* 主叫 offer 编码偏好（createOffer 前，含 hold/resume 与网络恢复的
 * re-INVITE 路径）：「配置 ∩ 支持」非空 → SDP 只含交集、顺序=配置
 * 顺序；交集为空（该网络段只配了 G729 等不支持编码）→ 带全部 4 个
 * 支持编码兜底（OPUS,G722,PCMU,PCMA），不失败。每次 offer 前刷新。 */
- (void)applyCodecPreferencesForOffer:(SipCallSession *)session
{
    if (session.peerConnection == nil) {
        return;
    }
    NSString *network = self.currentNetworkName;
    NSArray<NSNumber *> *ids = SipParseCodecOrder(self.effectiveCodecOrder);
    if (ids.count == 0) {
        NSMutableArray<NSNumber *> *fallback = [NSMutableArray array];
        for (int i = 0; i < kCodecFallbackOrderCount; i++) {
            [fallback addObject:@(kCodecFallbackOrder[i])];
        }
        ids = fallback;
        [self webrtcLog:@"codec 配置无可支持编码（纯 G729 段）-> offer 兜底全部 4 编码 %@ (network=%@)",
            SipCodecNamesOfIds(ids), network];
    }
    [self applyCodecPreferences:session.peerConnection
                       codecIds:ids
                          phase:@"offer"
                        network:network];
}

/* 被叫 answer 编码偏好（SRD 之后 createAnswer 前）：offer∩配置∩支持
 * 非空 → 设偏好（交集、顺序=配置顺序）；为空（如服务器 offer 只带
 * G729，或配置与 offer 无公共支持编码）→ 不设偏好不做兜底，协商按
 * 现有路径自然失败（用户确认语义——被叫不迁就，双端一致）。 */
- (void)applyCodecPreferencesForAnswer:(SipCallSession *)session
                              offerSdp:(NSString *)offerSdp
{
    if (session.peerConnection == nil) {
        return;
    }
    NSString *network = self.currentNetworkName;
    NSArray<NSNumber *> *configIds = SipParseCodecOrder(self.effectiveCodecOrder);
    NSSet<NSString *> *offerNames = SipAudioCodecNamesFromSdp(offerSdp);
    NSMutableArray<NSNumber *> *inter = [NSMutableArray array];
    for (NSNumber *idNum in configIds) {
        if ([offerNames containsObject:SipCodecNameForId(idNum.intValue)]) {
            [inter addObject:idNum];
        }
    }
    if (inter.count == 0) {
        [self webrtcLog:@"answer 编码交集为空（offer=%@, 配置=%@）-> 不设偏好，协商自然失败 (call %ld, network=%@)",
            offerNames, SipCodecNamesOfIds(configIds),
            (long)session.callId, network];
        return;
    }
    [self applyCodecPreferences:session.peerConnection
                       codecIds:inter
                          phase:@"answer"
                        network:network];
}

/* 按目标 ID 顺序从引擎全量 audio capability 现取实例设偏好（capability
 * 必须取自 factory——native 对 fmtp 参数严格匹配（opus 自带
 * minptime=10/useinbandfec=1），手工构造空参数会被 setCodecPreferences
 * 以 InvalidModification 拒绝，与安卓同因同解）。顺序即优先级。 */
- (void)applyCodecPreferences:(RTCPeerConnection *)pc
                     codecIds:(NSArray<NSNumber *> *)codecIds
                        phase:(NSString *)phase
                      network:(NSString *)network
{
    if (self.factory == nil || codecIds.count == 0) {
        return;
    }
    RTCRtpCapabilities *capabilities = nil;
    @try {
        capabilities = [self.factory
            rtpSenderCapabilitiesForKind:kRTCMediaStreamTrackKindAudio];
    } @catch (NSException *exception) {
        [self webrtcLog:@"getRtpSenderCapabilities failed (%@): %@",
            phase, exception];
        return;
    }
    if (capabilities == nil || capabilities.codecs.count == 0) {
        [self webrtcLog:@"codec capability 缺失 -> 保持引擎默认 (%@)", phase];
        return;
    }
    NSMutableArray<RTCRtpCodecCapability *> *preferred =
        [NSMutableArray array];
    for (NSNumber *idNum in codecIds) {
        NSString *mime = SipCodecMimeForId(idNum.intValue);
        if (mime == nil) {
            continue;
        }
        for (RTCRtpCodecCapability *cap in capabilities.codecs) {
            if (cap.mimeType != nil
                && [cap.mimeType caseInsensitiveCompare:mime] == NSOrderedSame
                && ![preferred containsObject:cap]) {
                [preferred addObject:cap];
                break;
            }
        }
    }
    if (preferred.count == 0) {
        [self webrtcLog:@"codec capability 匹配为空 %@ -> 保持引擎默认 (%@)",
            SipCodecNamesOfIds(codecIds), phase];
        return;
    }
    /* telephone-event 恒随列表尾(RFC 4733 DTMF):它是事件载荷不是音频
     * 编码,编码过滤把它排除 = offer/answer 均不含 101,dtmfSender
     * canInsertDtmf 恒 false、DTMF 永不可用(offer 带 telephone-event
     * 而 answer 丢失,按键全落 unavailable)。offer
     * 不带 telephone-event 时协商自然不含,不受影响;capability 仍取自
     * factory 实例(fmtp 自带,与编码同因) */
    for (RTCRtpCodecCapability *cap in capabilities.codecs) {
        if (cap.mimeType != nil
            && [cap.mimeType caseInsensitiveCompare:@"audio/telephone-event"]
                    == NSOrderedSame) {
            [preferred addObject:cap];
            break;
        }
    }
    BOOL ok = YES;
    @try {
        for (RTCRtpTransceiver *t in pc.transceivers) {
            if (t.mediaType != RTCRtpMediaTypeAudio) {
                continue;
            }
            NSError *error = nil;
            if (![t setCodecPreferences:preferred error:&error]) {
                ok = NO;
                [self webrtcLog:@"setCodecPreferences failed (%@): %@",
                    phase, error.localizedDescription ?: @"unknown error"];
            }
        }
    } @catch (NSException *exception) {
        ok = NO;
        [self webrtcLog:@"setCodecPreferences exception (%@): %@",
            phase, exception];
    }
    if (ok) {
        [self webrtcLog:@"%@ codecs=%@ (network=%@)",
            phase, SipCodecNamesOfIds(codecIds), network];
    }
}

/* 当前网络类型下的配置 ID 串（蜂窝→codecOrder3G 表；wifi/未知→
 * codecOrder 表；未下发/空串回退默认 order） */
- (NSString *)effectiveCodecOrder
{
    NSString *order = [self.currentNetworkName isEqualToString:@"cellular"]
        ? self.codecOrderCellular
        : self.codecOrderWifi;
    if (order.length == 0) {
        return kCodecDefaultOrder;
    }
    return order;
}

/* 音频路由（语义见头文件）。同步返回结果（bridge 契约需要）——
 * AVAudioSession API 线程安全，不经 runOnMain 异步转投 */
- (BOOL)setAudioRoute:(NSInteger)route
{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    AVAudioSessionPortOverride override =
        (route == SipAudioRouteSpeaker) ? AVAudioSessionPortOverrideSpeaker
                                         : AVAudioSessionPortOverrideNone;
    /* 呼出期（音频单元未启动、会话无输入活动）实测端口 override 写入
     * 成功但不改变实际输出——回铃音仍走听筒，按钮亮暗均无听感变化
     * （iOS 26.5 真机实测）。此时按目标路由翻转 defaultToSpeaker
     * 类别选项并（重）设通话会话，触发系统重算输出：亮=扬声器外放、
     * 暗=听筒，与按钮状态一致。仅音频未运行时做——运行中 override 本就
     * 即时生效，也避免与活动单元的 AEC 配置互踩；setCategory 同值重设
     * 也会清 override（实测确认），故先重设选项、后写 override。
     * 不以「会话已在 playAndRecord」为前提——expo-audio（录音/语音信箱/
     * 转录回显屏挂载即 ensureAudioMode）会把共享会话写成 .playback 且
     * 无人清回，原前提在借走后形成死锁：分支永不进、.playback 下
     * speaker override 直接 -50（回铃期切换全失败）。
     * 音频未运行即收回通话配置，callMake/callAnswer 的初始重置
     * 同样经此收口——拨号一刻收回，回铃音即在通话会话下默认走听筒。
     * 接通时单元启动重设回 WebRTC 配置，选项/override 残留由
     * audioSessionDidStartPlayOrRecord 按标志双写收口
     * （applySpeakerCategoryAndOverride） */
    if (![RTCAudioSession sharedInstance].isAudioEnabled) {
        NSString *previousCategory = audioSession.category;
        BOOL wasCallConfig =
            [previousCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord];
        AVAudioSessionCategoryOptions options =
            (override == AVAudioSessionPortOverrideSpeaker)
                ? AVAudioSessionCategoryOptionDefaultToSpeaker
                : 0;
        NSError *configError = nil;
        if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                  mode:AVAudioSessionModeVoiceChat
                               options:options
                                 error:&configError]) {
            [self engineLog:@"setAudioRoute(%ld) re-configure FAILED: %@",
                (long)route, configError.localizedDescription ?: @"unknown error"];
        } else if (wasCallConfig) {
            [self engineLog:@"audio session re-configured (defaultToSpeaker=%@)",
                options != 0 ? @"YES" : @"NO"];
        } else {
            /* 从播放器配置收回通话会话（复测判据），%@ 为收回前 category */
            [self engineLog:@"audio session reclaimed from %@ (defaultToSpeaker=%@)",
                previousCategory, options != 0 ? @"YES" : @"NO"];
        }
    }
    NSError *error = nil;
    if (![audioSession overrideOutputAudioPort:override error:&error]) {
        [self engineLog:@"setAudioRoute(%ld) FAILED: %@",
            (long)route, error.localizedDescription ?: @"unknown error"];
        return NO;
    }
    self.speakerOverride = (override == AVAudioSessionPortOverrideSpeaker);
    [self engineLog:@"setAudioRoute(%ld) OK (override=%@)", (long)route,
        override == AVAudioSessionPortOverrideSpeaker ? @"speaker" : @"none"];
    return YES;
}

/* 新通话初始听筒重置：扬声器是「通话内」的用户选择，不跨通话继承——
 * speakerOverride 与 AVAudioSession port override 在 category 保持
 * playAndRecord/voiceChat 时持续生效（WebRTC audio unit 停用只
 * setActive(NO)，不恢复 category），上一通开过的扬声器会残留到下一通：
 * 新呼出/接听的首帧快照据残留 override 上报 Speaker，WebRTC audio
 * unit 激活重新 setCategory（同值也会清除 port override）后又回落
 * 听筒——表现为呼出闪亮。仅当本通话外无其他非终态
 * 会话时执行——双通话（咨询转等）中既有通话的扬声器选择不因新呼出/
 * 接听被全局关掉（override 为会话级全局） */
- (void)resetAudioRouteForNewCallExcluding:(NSInteger)callId
{
    for (SipCallSession *session in [self.registry snapshot]) {
        if (!session.isTerminal && session.callId != callId) {
            return;
        }
    }
    [self setAudioRoute:SipAudioRouteReceiver];
}

/* 单元启动边界的扬声器双写（didStartPlayOrRecord 重放与延迟重申共用）：
 * setCategory 补 defaultToSpeaker 选项 + override，缺一不可——
 * 1. 只写裸 override：通知到达时输入活动可能尚未建立，写进无输入窗口
 *    声学无效（iOS 26.5 实测），系统在输入建立时按类别选项
 *    重算路由（WebRTC 启动配置 options=0 → 听筒）——「亮着接通实走
 *    听筒」即此（重放两行日志齐全、按钮亮，仍听筒）；
 * 2. 只设选项不写 override：IO 已跑时需 override 才即时切道（与接通后
 *    手动切换同机制），快照上报语义也依赖 override 即时生效。
 * 选项粘在会话配置上，兜住输入建立时点的路由重算（与回铃期修复同
 * 机制）。先重设选项、后写 override——同值 setCategory 亦清 override
 * （实测确认），顺序不能倒。仅通话配置下执行（expo-audio 借走
 * 会话的 .playback 期间无意义）。主线程调用 */
- (BOOL)applySpeakerCategoryAndOverride
{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if (![audioSession.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
        || ![audioSession.mode isEqualToString:AVAudioSessionModeVoiceChat]) {
        return NO;
    }
    NSError *configError = nil;
    if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                              mode:AVAudioSessionModeVoiceChat
                           options:AVAudioSessionCategoryOptionDefaultToSpeaker
                             error:&configError]) {
        [self engineLog:@"speaker re-apply setCategory FAILED: %@",
            configError.localizedDescription ?: @"unknown error"];
        return NO;
    }
    NSError *error = nil;
    if (![audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                         error:&error]) {
        [self engineLog:@"speaker re-apply override FAILED: %@",
            error.localizedDescription ?: @"unknown error"];
        return NO;
    }
    return YES;
}

/* RTCAudioSessionDelegate（ensureWebRtc 挂载，弱持有）。audio unit 每次
 * 初始化/启动（呼出/接通、Hold 恢复、打断恢复）都会重设 category——同值
 * setCategory 也会清除 port override（实测确认），把 setAudioRoute
 * 写入的扬声器 override 清掉而 speakerOverride 标志仍在：按钮点亮、音频
 * 实走听筒。unit 启动后按标志重放——重放必须
 * 走 applySpeakerCategoryAndOverride 双写：此前经 setAudioRoute 的重放在
 * 接通后必被 isAudioEnabled=1 跳过选项分支、只剩裸 override，单发扛不住
 * 单元启动的配置竞争（真机复测曾失守），另补 kSipSpeakerReassertSec
 * 延迟重申兜住晚于重放的 WebRTC 再一轮 setCategory。回调在 WebRTC
 * 线程——转主线程执行并二次校验 */
- (void)audioSessionDidStartPlayOrRecord:(RTCAudioSession *)session
{
    /* 无条件打点：audio unit 启动是「接通无声」的分水岭
     * （传输/门控/CallKit 激活全 OK 仍可能无声，ADM 层需观测点） */
    [self engineLog:@"audio unit play/record STARTED"];
    if (!self.speakerOverride) {
        return;
    }
    [self runOnMain:^{
        if (!self.speakerOverride) {
            return;
        }
        if ([self applySpeakerCategoryAndOverride]) {
            [self engineLog:@"speaker override re-applied after audio unit start"];
        }
        /* 延迟单发重申：窗口内用户熄灭 / 新通话重置（speakerOverride=NO）
         * 即跳过；引擎为进程级单例，self 强持无泄漏 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kSipSpeakerReassertSec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.speakerOverride) {
                return;
            }
            if ([self applySpeakerCategoryAndOverride]) {
                [self engineLog:@"speaker override re-asserted after start settle"];
            }
        });
    }];
}

/* 音频会话观测组（纯日志零行为）：
 * STOPPED 补全单元生命周期观测；canPlayOrRecord 是 WebRTC 侧会话可用性
 * 判定（悬挂恢复后若持续 NO，单元不会启动）；interruption 观测悬挂/唤醒
 * 在音频会话层的表现。均无需转主线程——engineLog 仅写日志管道 */
- (void)audioSessionDidStopPlayOrRecord:(RTCAudioSession *)session
{
    [self engineLog:@"audio unit play/record STOPPED"];
}

- (void)audioSession:(RTCAudioSession *)session
    didChangeCanPlayOrRecord:(BOOL)canPlayOrRecord
{
    [self engineLog:@"audio session canPlayOrRecord=%d", canPlayOrRecord];
}

- (void)audioSessionDidBeginInterruption:(RTCAudioSession *)session
{
    [self engineLog:@"audio session interruption BEGIN"];
}

- (void)audioSessionDidEndInterruption:(RTCAudioSession *)session
                   shouldResumeSession:(BOOL)shouldResumeSession
{
    [self engineLog:@"audio session interruption END (shouldResume=%d)",
        shouldResumeSession];
}

/* 当前音频路由推导（RN AudioRoute 契约值）：
 * 0. 通话音频会话门控——会话不在通话配置（playAndRecord + voiceChat，
 *    ensureWebRtc 所设）时一律报听筒：expo-audio（回铃/提示音等播放器
 *    路径）会把共享 AVAudioSession 改成 .playback/.default 并在播完
 *    setActive(false)，此时 currentRoute 的输出口是内置扬声器（媒体
 *    路由），据此上报 Speaker 会让 RN 扬声器按钮在呼出首帧误高亮、
 *    待 WebRTC 音频单元激活恢复通话配置后再回落（闪亮）。WebRTC 的
 *    playAndRecord 配置 mode 恒为 voiceChat，expo-audio 恒为 .default，
 *    两者可靠可区分；
 * 1. 已连接外设优先——蓝牙/耳机插着时 override 不改道（iOS 语义），
 *    如实上报外设路由，RN 侧据此走系统路由选择器；
 * 2. 无外设时 override==speaker → 扬声器；
 * 3. 其余按 currentRoute 实际输出口映射（iPad 等无听筒设备默认
 *    builtInSpeaker → 扬声器；iPhone 默认 builtInReceiver → 听筒） */
- (NSInteger)currentAudioRoute
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
        || ![session.mode isEqualToString:AVAudioSessionModeVoiceChat]) {
        return SipAudioRouteReceiver;
    }
    /* 拨号期/接听激活窗口门控：会话在通话配置但通话音频尚未运行时，
     * AVAudioSession 处于失活或仅播放态（回铃音），iOS 对无活动音频
     * 输入的 playAndRecord 会话按播放语义选择输出，currentRoute 报
     * BuiltInSpeaker——首帧快照据此误报 Speaker，接通（audio unit
     * 激活、输入就绪）后 route 回落听筒才熄灭，表现为呼出闪亮
     * 。两个误报窗口：
     * 1. 拨号期：无已接通会话（呼出 Trying/Ringing、挂断后终态滞留）；
     * 2. 接听激活窗口：来电接通帧（IncomingAnswered）快照时会话已
     *    established，但 CallKit 手动音频门（useManualAudio）未开——
     *    didActivate 晚于 200 OK，isAudioEnabled 仍为 0，WebRTC 音频
     *    单元未启动，CallKit 已激活的 playAndRecord 会话同样无活动
     *    音频输入：接通首帧误报 Speaker 让 RN 扬声器按钮高亮、实际
     *    音频随 unit 启动走听筒，且此后无状态变化刷新 audioRoute，
     *    高亮卡死。
     * isAudioEnabled 精确覆盖窗口 2：开门由接通帧之后的 establishedViews
     * （呼出）或 didActivate（来电）驱动，快照时点必为 0，unit 启动后
     * 为 1。此阶段通话音频尚未建立，固定报听筒；仅用户显式 override
     * （拨号期预开免提，callMake/callAnswer 已重置跨通话残留）如实
     * 上报。registry 仅主线程可碰——既有消费方（NovoEventHandler
     * 快照组包）即主线程调用 */
    if (![self hasEstablishedSession]
        || ![RTCAudioSession sharedInstance].isAudioEnabled) {
        return self.speakerOverride ? SipAudioRouteSpeaker
                                    : SipAudioRouteReceiver;
    }
    NSInteger external = 0;
    NSInteger builtIn = SipAudioRouteReceiver;
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
            external = SipAudioRouteBluetoothA2DP;
        } else if ([port.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                   [port.portType isEqualToString:AVAudioSessionPortBluetoothLE]) {
            external = SipAudioRouteBluetoothSCO;
        } else if ([port.portType isEqualToString:AVAudioSessionPortHeadphones] ||
                   [port.portType isEqualToString:AVAudioSessionPortUSBAudio]) {
            external = SipAudioRouteHeadset;
        } else if ([port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            builtIn = SipAudioRouteSpeaker;
        }
    }
    if (external != 0) {
        return external;
    }
    if (self.speakerOverride) {
        return SipAudioRouteSpeaker;
    }
    return builtIn;
}

/* 是否存在已接通（非终态 Established/IncomingAnswered）会话——通话
 * 音频是否在跑的引擎侧判定（currentAudioRoute 拨号期门控用）。
 * 主线程限定（registry 契约，见 currentAudioRoute 注释） */
- (BOOL)hasEstablishedSession
{
    for (SipCallSession *session in [self.registry snapshot]) {
        if (session.isTerminal) {
            continue;
        }
        if ([session.callStateView isEqualToString:SipCallStateEstablished]
            || [session.callStateView isEqualToString:SipCallStateIncomingAnswered]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - 呼叫操作

- (BOOL)hasAnySession
{
    return [self.registry snapshot].count > 0;
}

- (void)setCallsInRecentsEnabled:(BOOL)enabled
{
    [self runOnMain:^{
        [self.callKitCoordinator setCallsInRecentsEnabled:enabled];
    }];
}

/* 呼出链（安卓 callMake:457-488 + startOutgoingCall:491-536）：
 * registry.create(OUT) → X-Request-ID 头注入 → PC 建立 → createOffer
 * → SLD → gather 看门狗(双窗：800ms 兜底/候选后 150ms) → ys_make_call_with_sdp（callId 回填，
 * awaitingAnswer=true） */
- (void)callMake:(NSString *)number requestId:(NSString *)requestId
{
    [self callMake:number requestId:requestId callKitUuid:nil];
}

/* uuid 变体（coordinator action fulfill / 系统记录回拨路径——终态时
 * reportCallEnded 按 uuid 定位系统卡片） */
- (void)callMake:(NSString *)number
       requestId:(NSString *)requestId
    callKitUuid:(NSUUID *)uuid
{
    [self runOnMain:^{
        if (!self->_started) {
            [self engineLog:@"start first"];
            [self notifyCallStartFailed:number requestId:requestId
                                 reason:@"engine not started"];
            return;
        }
        if (!self.isWebRtcReady) {
            [self engineLog:@"WebRTC unavailable - cannot dial"];
            [self notifyCallStartFailed:number requestId:requestId
                                 reason:@"WebRTC unavailable"];
            return;
        }
        /* 新通话初始听筒：会话创建前重置（registry 中非终态会话均为
         * 其他通话，gather 窗口期会话 callId=-1 与本参数同值一并排除） */
        [self resetAudioRouteForNewCallExcluding:-1];
        SipCallSession *session =
            [self.registry createSessionWithDirection:SipCallDirectionOut];
        if (session == nil) {
            [self engineLog:@"call rejected: MAX_CONCURRENT (%ld)",
                (long)SipCallSessionRegistry.maxSessions];
            [self notifyCallStartFailed:number requestId:requestId
                                 reason:@"MAX_CONCURRENT"];
            return;
        }
        session.remoteNumber = number;
        session.requestId = requestId;
        session.callKitUuid = uuid;
        /* groupId 创建即赋且保持稳定（= 前缀 + sessionId）：ICE gather 窗口期
         * （最长看门狗窗，INVITE 未提交）JS 的挂断等操作已可经 entry 定位；
         * INVITE 提交获得 pjsua callId 后也不得改写（JS 持有的旧
         * entry.groupId 会失效）。
         * 前缀 SipGroupIdOutgoingPrefix 命名空间隔离：来电 groupId =
         * String(callId)（onIncomingCall），sessionId 与 callId 独立递增，
         * 裸数字串会撞号（首呼出 sessionId=1 == 次来电 callId=1），导致 RN
         * 侧两路通话同 id、组合操作第二步接听被 isStillAnswerable 误跳过
         * （详见 SipCallSession.h groupId 注释） */
        session.groupId = [NSString stringWithFormat:@"%@%lld",
                              SipGroupIdOutgoingPrefix, session.sessionId];
        [self engineLog:@"call out -> %@%@",
            number,
            requestId.length > 0
                ? [NSString stringWithFormat:@" (X-Request-ID %@)", requestId]
                : @""];

        /* gather 窗口期首帧：createOffer→ICE 收集（候选去抖窗即发）
         * 期间 INVITE 未发，此前 JS 对本通呼叫零感知——拨号后通话面板要等
         * 到 INVITE 发出才弹（网络差时最长 800ms）。会话创建即推 Trying 快照，
         * 面板立即可见"呼叫中"；sendInviteWithLocalSdp 提交后再置 Trying
         * 幂等无副作用。窗口期挂断经 callHangupByGroupId 本地终结
         * （groupId 创建即稳定是定位前提），对齐安卓 RefreshCallViews 时机 */
        session.callStateView = SipCallStateTrying;
        [self notifySessionChanged:session];

        [self startOutgoingCall:session];
    }];
}

/* 接听来电（安卓 answerInternal:554-595） */
- (void)callAnswer:(NSInteger)callId
{
    [self runOnMain:^{
        if (!self->_started) {
            [self engineLog:@"start first"];
            return;
        }
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil || !session.isIncoming) {
            [self engineLog:@"answer: no incoming call %ld", (long)callId];
            return;
        }
        if (session.answerRequested || session.isTerminal) {
            [self engineLog:@"answer: call %ld already handled", (long)callId];
            return;
        }
        if (![session.callStateView isEqualToString:SipCallStateIncomingTrying]
            && ![session.callStateView isEqualToString:SipCallStateIncomingRinging]) {
            [self engineLog:@"answer: call %ld not in ringing state (%@)",
                (long)callId, session.callStateView];
            return;
        }
        if (!self.isWebRtcReady) {
            [self engineLog:@"WebRTC unavailable - cannot answer"];
            return;
        }
        if (session.offerSdp.length == 0) {
            /* 呼入 offer 损坏/缺失：ys_reject_call 固定发 486 Decline
             * （语义等价"拒接"，服务器侧都按被叫拒绝收口） */
            [self engineLog:@"answer: offer missing -> reject 486"];
            /* 本端发起的 486：DISCONNECTED 重算按拒接收口（否则落入
             * Missed 误判） */
            session.rejectRequested = YES;
            ys_reject_call((pjsua_call_id)callId);
            return;
        }

        session.answerRequested = YES;
        [SipRingtoneHelper stopRingtone];
        /* 新通话初始听筒：接听同样不继承上一通的扬声器选择（来电路径
         * 与呼出同根因，一并收口） */
        [self resetAudioRouteForNewCallExcluding:callId];
        [self engineLog:@"answering incoming call %ld", (long)callId];

        [self setupPeerConnection:session];
        if (session.peerConnection == nil) {
            session.answerRequested = NO;
            [self engineLog:@"WebRTC unavailable - cannot answer incoming call"];
            return;
        }
        [self answerRemoteOffer:session offerSdp:session.offerSdp];
        [self notifySessionChanged:session];
    }];
}

/* 拒接来电（安卓 rejectInternal:612-636） */
- (void)callReject:(NSInteger)callId
{
    [self runOnMain:^{
        if (!self->_started) {
            return;
        }
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil || !session.isIncoming) {
            [self engineLog:@"reject: no incoming call %ld", (long)callId];
            return;
        }
        if (session.answerRequested || session.isTerminal) {
            [self engineLog:@"reject: call %ld already handled (%@)",
                (long)callId, session.callStateView];
            return;
        }
        session.rejectRequested = YES;
        [SipRingtoneHelper stopRingtone];
        if (ys_reject_call((pjsua_call_id)callId) != 0) {
            [self ysLog:@"ys_reject_call failed"];
            session.rejectRequested = NO;
            return;
        }
        [self ysLog:@"rejected 486 (call %ld)", (long)callId];
        /* 视图乐观置终态（DISCONNECTED 事件到达后幂等） */
        session.callStateView = SipCallStateIncomingRejected;
        [self onSessionTerminated:session];
        [self notifySessionChanged:session];
    }];
}

/* 挂断（安卓 callHangup:639-663）。呼出未提交 INVITE 的会话 callId<0，
 * findByCallId 拒绝负值无法定位——该窗口期挂断由 callHangupByGroupId
 * 承接（安卓引擎此处同为 no-op，是其待回溯缺陷，非对齐基准） */
- (void)callHangup:(NSInteger)callId
{
    [self runOnMain:^{
        if (!self->_started) {
            return;
        }
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil) {
            [self engineLog:@"hangup: no call %ld", (long)callId];
            return;
        }
        if (session.isTerminal) {
            return;
        }
        BOOL sent = NO;
        if (session.callId >= 0) {
            sent = (ys_hangup_call((pjsua_call_id)session.callId) == 0);
        }
        if (!sent) {
            [self ysLog:@"hangup %ld failed (or not sent)", (long)session.callId];
        }
        /* 事实标志先行：DISCONNECTED 重算终态时按此归 Terminated，
         * 而非落入 view 历史判据（被下方乐观置值污染）误判 Missed */
        session.hangupRequested = YES;
        session.callStateView = SipCallStateTerminated;
        [self onSessionTerminated:session];
        [self notifySessionChanged:session];
    }];
}

/* 按 groupId 挂断（gather 窗口期专用入口，语义见 .h 注释）。终结序列
 * 与 callHangup 一致：callId>=0 竞态窗口补 BYE/CANCEL，本地 view=Terminated
 * → onSessionTerminated（closePeerConnection 连带撤看门狗/停回铃）→
 * 终态滞回后清除推空 callList，RN 面板 >0→0 收口，再呼出可正常弹屏 */
/* 呼出会话本地终结单点实现（groupId 挂断 / CallKit 窗口期挂断共用）：
 * INVITE 已提交的竞态窗口（callId>=0）照常 BYE/CANCEL，否则纯本地终结
 * → view=Terminated → onSessionTerminated（closePeerConnection 连带撤
 * 看门狗/停回铃）→ 终态滞回后清除推空 callList。调用方负责已查得
 * 会话（按 groupId 或 uuid）且非终态 */
- (void)terminateOutgoingSession:(SipCallSession *)session context:(NSString *)context
{
    if (session.callId >= 0) {
        /* 竞态窗口：看门狗刚提交 INVITE（callId 已回填）——照常 BYE/CANCEL */
        if (ys_hangup_call((pjsua_call_id)session.callId) != 0) {
            [self ysLog:@"%@: hangup call %ld failed",
                context, (long)session.callId];
        }
    } else {
        [self engineLog:@"%@: pre-INVITE -> local terminate", context];
    }
    session.callStateView = SipCallStateTerminated;
    [self onSessionTerminated:session];
    [self notifySessionChanged:session];
}

- (void)callHangupByGroupId:(NSString *)groupId
{
    [self runOnMain:^{
        if (!self->_started) {
            return;
        }
        SipCallSession *session = [self.registry findByGroupId:groupId];
        if (session == nil) {
            [self engineLog:@"hangup: no session (group %@)", groupId];
            return;
        }
        if (session.isTerminal) {
            return;
        }
        [self terminateOutgoingSession:session
            context:[NSString stringWithFormat:@"hangup (group %@)", groupId]];
    }];
}

/* hold/resume 入口（安卓 callHold:906-922 → holdInternal:924-959） */
- (void)callHold:(NSInteger)callId held:(BOOL)held
{
    [self runOnMain:^{
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil || session.peerConnection == nil) {
            [self engineLog:@"%@: no call %ld",
                held ? @"hold" : @"resume", (long)callId];
            return;
        }
        if (session.isTerminal) {
            return;
        }
        [self holdInternal:session held:held];
    }];
}

/* 静音/取消静音（安卓 callMute:991-1008）：track isEnabled，不发 re-INVITE */
- (void)callMute:(NSInteger)callId muted:(BOOL)muted
{
    [self runOnMain:^{
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil) {
            return;
        }
        if (session.muteFlag == muted) {
            return;
        }
        session.muteFlag = muted;
        [self applyTrackEnabled:session];
        [self webrtcLog:@"call %ld mute=%@", (long)session.callId,
            muted ? @"YES" : @"NO"];
        [self notifySessionChanged:session];
    }];
}

/* 盲转（安卓 callXfer:788-803） */
- (void)callXfer:(NSInteger)callId to:(NSString *)dest
{
    [self runOnMain:^{
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil || session.isTerminal) {
            [self engineLog:@"xfer: no call %ld", (long)callId];
            return;
        }
        int rc = ys_xfer_call((pjsua_call_id)session.callId,
                              dest.UTF8String ?: "");
        [self engineLog:@"blind xfer %@ -> %@", dest, rc == 0 ? @"sent" : @"failed"];
    }];
}

/* 咨询转（安卓 callXferAttended:809-827） */
- (void)callXferAttended:(NSInteger)callId destCallId:(NSInteger)destCallId
{
    [self runOnMain:^{
        SipCallSession *a = [self.registry findByCallId:callId];
        SipCallSession *b = [self.registry findByCallId:destCallId];
        if (a == nil || b == nil || a.isTerminal || b.isTerminal) {
            [self engineLog:@"attended xfer: missing call %ld/%ld",
                (long)callId, (long)destCallId];
            return;
        }
        int rc = ys_xfer_replaces_call((pjsua_call_id)a.callId,
                                       (pjsua_call_id)b.callId);
        [self engineLog:@"attended xfer %ld x %ld -> %@",
            (long)callId, (long)destCallId, rc == 0 ? @"sent" : @"failed"];
    }];
}

/* 通话中 DTMF（安卓 callDtmf:835-873）：遍历 senders 取 dtmfSender，
 * canInsertDtmf 校验（未协商 telephone-event payload 则不可用），
 * insertDtmf(200ms, 100ms gap)；dtmfOff 契约由桥接层 no-op */
- (void)callDtmf:(NSInteger)callId digits:(NSString *)digits
{
    [self runOnMain:^{
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil || session.isTerminal || session.audioTrack == nil) {
            [self engineLog:@"dtmf: no call %ld", (long)callId];
            return;
        }
        if (digits.length == 0) {
            return;
        }
        @try {
            id<RTCDtmfSender> sender = nil;
            for (RTCRtpSender *rtpSender in session.peerConnection.senders) {
                if (rtpSender.dtmfSender != nil) {
                    sender = rtpSender.dtmfSender;
                    break;
                }
            }
            if (sender == nil || !sender.canInsertDtmf) {
                [self webrtcLog:@"dtmf sender unavailable (telephone-event not negotiated)"];
                return;
            }
            BOOL ok = [sender insertDtmf:digits
                                 duration:kSipDtmfDuration
                             interToneGap:kSipDtmfInterToneGap];
            [self webrtcLog:@"dtmf %@ -> %@", digits, ok ? @"sent" : @"failed"];
        } @catch (NSException *exception) {
            [self webrtcLog:@"dtmf exception: %@", exception];
        }
    }];
}

/* 通话质量统计（安卓 getCallQuality:702-730 + parseQuality:733-785；
 * JSON 组包对齐安卓 CallDelegate.getCallQualityJson：
 * {bars, network, codec, jitterMs, packetLossPct, roundTripMs}） */
- (void)getCallQuality:(NSInteger)callId completion:(void (^)(NSString * _Nullable))completion
{
    [self runOnMain:^{
        if (completion == nil) {
            return;
        }
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil) {
            /* 无该通话：对齐安卓 delegate 侧回空串（桥接 resolve ""） */
            completion(nil);
            return;
        }
        if (session.peerConnection == nil) {
            /* 有会话无 PC（终态滞留等）：对齐安卓回 valid=false 统计
             * （bars 中性 3 格 + OPUS 兜底） */
            completion([self qualityJsonWithReport:nil]);
            return;
        }
        RTCPeerConnection *pc = session.peerConnection;
        [pc statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self qualityJsonWithReport:report]);
            });
        }];
    }];
}

#pragma mark - 快照

- (NSArray<NSDictionary *> *)snapshotCalls
{
    /* 任意时刻可查契约：先清到期的终态滞留会话，再取插入序快照 */
    [self.registry purgeExpiredNow];
    NSMutableArray<NSDictionary *> *result = [[NSMutableArray alloc] init];
    for (SipCallSession *session in [self.registry snapshot]) {
        /* CallKit 模式来电弹屏退役（R5/AC-3，check 修复）：未接听的来电
         * 会话不上抛。RN 侧 IncomingCallScreen 由全量 callList 驱动——
         * StateChanged 事件与 getActiveCalls 冷启动 hydrate 均消费本快照，
         * 保留振铃条目会把 RN 来电屏与 CallKit 系统卡片叠现。
         * 判据 = callKitUuid 已绑定（系统卡片接管展示）：reportNewIncomingCall
         * 失败时 onCallKitReportFailedForUuid 解绑 uuid，会话即回到快照，
         * 来电屏回退一阶段 RN 弹屏兜底（异常矩阵 4.3.4）。
         * 接听后（IncomingAnswered 起）照常上抛——通话中 UI 拉起不受影响；
         * 未接听即终态（拒接/未接）仍上抛，RN 侧 prevCalls 为空走
         * "历史来电回放跳过面板"分支，无叠现。coordinator 未就绪
         * （nil）时全量上抛。 */
        if (_callKitCoordinator != nil && session.isIncoming
            && session.callKitUuid != nil
            && ([session.callStateView isEqualToString:SipCallStateIncomingTrying]
                || [session.callStateView isEqualToString:SipCallStateIncomingRinging])) {
            continue;
        }
        [result addObject:[session toDictionary]];
    }
    return result;
}

#pragma mark - CallKit 协作面（二阶段新增）

- (BOOL)hasRegisteredAccount
{
    /* 仅主线程调用（_accId 引擎主线程读写；AppDelegate 唤醒门面在主队列
     * 查询，唤醒注册路径经 DispatchQueue.main.sync 转投） */
    return _started && _accId >= 0;
}

/* 查询同号码未终结来电的已绑卡片 uuid——INVITE 先到（前台在线双发场景）
 * 由 handleIncomingSdp 现场 report 过、会话已绑卡且未终结。覆盖振铃与
 * 已接听两态：弱网下 push 可晚于用户接听到达，仅匹配振铃态会 MISS 而
 * 补出幽灵卡。判据用 isTerminal 契约方法（终态集单点维护，天然覆盖
 * Trying/Ringing/Answered）；号码比较与 coordinator matchIncoming 同源
 * （trim + 严格相等）。stateView 出参供去重日志区分场景。
 * 引擎主线程调用。
 *
 * 同号新来电为何不会误吞（契约论证）：服务器
 * 对来电恒 push+INVITE 双发（不感知前后台），INVITE 与既有会话走同一
 * TCP 连接、可达性一致——① INVITE 先到（常态）：新会话现场 report 出
 * 卡，push 后到命中谁均有卡；② push 先到（弱网）被本去重吞：INVITE
 * 到达时 matchIncoming MISS 走现场 report 补卡，不漏接，仅弹卡时机
 * 后移；③ INVITE 不可达 = 来电已死，吞 push 反而避免幽灵卡。代价仅
 * ②的弹卡延迟。前提：push payload 无通话级标识（仅 traceId 实例 id），
 * 无法精确关联，故以号码+未终结为界 */
- (NSUUID *)uuidOfOngoingIncomingCallMatching:(NSString *)callerNumber
                                    stateView:(NSString **)stateView
{
    NSString *target = [callerNumber stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
    if (target.length == 0) { return nil; }
    for (SipCallSession *session in [self.registry snapshot]) {
        if (!session.isIncoming || session.callKitUuid == nil) { continue; }
        if ([session isTerminal]) { continue; }
        /* session 侧同样 trim（remoteNumber 来自 SIP From 头原值），
         * 与 matchIncoming 两侧均 trim 的比较保持一致 */
        NSString *sessionNumber = [session.remoteNumber stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
        if ([sessionNumber isEqualToString:target]) {
            if (stateView != NULL) { *stateView = session.callStateView; }
            return session.callKitUuid;
        }
    }
    return nil;
}

- (NSUUID *)reportIncomingCall:(NSUUID *)uuid
                    callerName:(NSString *)callerName
                  callerNumber:(NSString *)callerNumber
{
    /* PushKit 红线路径：AppDelegate 在 push 回调内同步调用——
     * reportNewIncomingCall 必须在回调返回前发起。coordinator 异常未就绪
     * 时返回 nil，走 RN 弹屏兜底（单点异常容错，见 detail 4.3.4） */
    if (_callKitCoordinator == nil) {
        [self engineLog:@"reportIncomingCall skipped: coordinator not ready"];
        return nil;
    }
    /* 本方法可能在 push 回调线程被同步调用（engine 单例 init 即创建
     * coordinator，无需等待 engineStart）；coordinator 内部状态仅主线程
     * 读写，此处主线程同步执行 */
    __block NSUUID *result = nil;
    void (^reportOnMain)(void) = ^{
        /* INVITE 先到去重：前台在线时服务器
         * push/INVITE 双发，INVITE 直收快于 APNs——同号码未接听来电已
         * 由 INVITE 路径现场 report（会话已绑卡片），push 路径不再重复
         * report，返回已有 uuid（report 决策单点化，对齐线上版 Acrobits
         * SDK 行为；该来电已有 CallKit 卡片，push 红线已满足） */
        NSString *existingState = nil;
        NSUUID *existing = [self uuidOfOngoingIncomingCallMatching:callerNumber
                                                         stateView:&existingState];
        if (existing != nil) {
            /* 命中即以 INVITE 先到的 report 为准（含 displayName），
             * push 携带的名称差异丢弃——同服务器双发两侧数据一致，
             * 不做已 report 卡片的显示名更新 */
            [self engineLog:@"push report dedup: incoming already reported (uuid=%@, number=%@, state=%@)",
                existing.UUIDString, callerNumber, existingState];
            result = existing;
            return;
        }
        result = [self->_callKitCoordinator reportIncomingCall:uuid
                                                     callerName:callerName
                                                   callerNumber:callerNumber];
    };
    if ([NSThread isMainThread]) {
        reportOnMain();
    } else {
        dispatch_sync(dispatch_get_main_queue(), reportOnMain);
    }
    return result;
}

- (void)startOutgoingCall:(NSString *)number requestId:(NSString *)requestId
{
    [self runOnMain:^{
        if (self->_callKitCoordinator == nil) {
            /* coordinator 异常未就绪：直呼兜底（单点容错，非模式开关） */
            [self callMake:number requestId:requestId];
            return;
        }
        /* CallKit 模式：经 CXStartCallAction（系统通话记录 + 音频会话由
         * CallKit 托管）；action fulfill 后引擎呼出，8s 未回调直呼兜底 */
        [self->_callKitCoordinator startCall:number
                                    requestId:requestId
                                makeCallBlock:^(NSUUID *callUuid) {
            [self callMake:number requestId:requestId callKitUuid:callUuid];
        }];
    }];
}

/* 呼出被拒（无会话无后续事件）→ 通知门面撤回排队中的呼出事件
 * （@optional，未实现则只记日志） */
- (void)notifyCallStartFailed:(NSString *)number
                    requestId:(NSString *)requestId
                       reason:(NSString *)reason
{
    if (self->_callback != nil
        && [self->_callback respondsToSelector:
               @selector(onCallStartFailed:requestId:reason:)]) {
        [self->_callback onCallStartFailed:number requestId:requestId
                                    reason:reason];
    }
}

- (NSInteger)callIdForCallKitUuid:(NSUUID *)uuid
{
    /* 引擎主线程（coordinator 动作回调在主队列） */
    for (SipCallSession *session in [self.registry snapshot]) {
        if ([session.callKitUuid isEqual:uuid]) {
            return session.callId;
        }
    }
    return -1;
}

- (BOOL)endUnboundOutgoingForUuid:(NSUUID *)uuid
{
    /* 主线程同步（runOnMain 直执行），coordinator 先登记 endActionUuids
     * 再调此处（sessionEnded 回查防重复上报依赖登记在前），返回是否
     * 终结了会话——NO 时 coordinator 撤销登记 */
    __block BOOL ended = NO;
    [self runOnMain:^{
        for (SipCallSession *session in [self.registry snapshot]) {
            if (![session.callKitUuid isEqual:uuid]) { continue; }
            if (session.isTerminal) { return; }
            [self terminateOutgoingSession:session context:@"callkit end"];
            ended = YES;
            return;
        }
    }];
    return ended;
}

- (void)callEndFromCallKit:(NSInteger)callId uuid:(NSUUID *)uuid
{
    [self runOnMain:^{
        SipCallSession *session = [self.registry findByCallId:callId];
        if (session == nil) {
            [self engineLog:@"callkit end: no session %ld", (long)callId];
            /* 登记与会话查找的间隙内会话已终结：sessionEnded 无从驱动，
             * 通知 coordinator 清登记防泄漏（endActionUuids 残留无人消费） */
            if (uuid != nil && self->_callKitCoordinator != nil) {
                [self->_callKitCoordinator onEngineEndNoSessionForUuid:uuid];
            }
            return;
        }
        if (session.isIncoming && !session.confirmedOnce) {
            [self engineLog:@"callkit end while ringing -> reject 486 (call %ld)",
                (long)callId];
            [self callReject:callId];
        } else {
            [self engineLog:@"callkit end in conversation -> hangup (call %ld)",
                (long)callId];
            [self callHangup:callId];
        }
    }];
}

- (void)notifyCallKitEvent:(NSDictionary *)event
{
    [self runOnMain:^{
        if (self->_callback) {
            [self->_callback onCallKitEvent:event];
        }
    }];
}

- (void)onCallKitAudioSessionActivated
{
    /* CXProviderDelegate didActivate（主队列）→ useManualAudio 模式下
     * 音频单元启停唯一驱动源 */
    [self runOnMain:^{
        [self cancelAudioForceWatchdog];
        RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
        if (!rtcSession.isAudioEnabled) {
            rtcSession.isAudioEnabled = YES;
            [self webrtcLog:@"[AUDIO] activate (didActivate -> enabled)"];
        } else {
            [self webrtcLog:@"[AUDIO] activate (already enabled)"];
        }
    }];
}

- (void)onCallKitReportFailedForUuid:(NSUUID *)uuid
{
    /* reportNewIncomingCall 失败（异常矩阵 4.3.4）：系统卡片不可用——
     * 解绑会话 uuid，未接听来电重新进入 RN 快照（snapshotCalls 的
     * CallKit 过滤按 uuid 绑定判定），来电屏回退一阶段 RN 弹屏兜底。
     * push 先行 report 失败时会话尚未创建（无匹配），此处安全空过 */
    [self runOnMain:^{
        for (SipCallSession *session in [self.registry snapshot]) {
            if ([session.callKitUuid isEqual:uuid]) {
                session.callKitUuid = nil;
                [self engineLog:@"callkit report failed -> unbind, RN fallback (call %ld)",
                    (long)session.callId];
                [self notifySessionChanged:session];
                return;
            }
        }
    }];
}

- (void)onCallKitAudioSessionDeactivated
{
    [self runOnMain:^{
        RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
        if (!rtcSession.isAudioEnabled) {
            return;
        }
        /* 系统对已终结那路的收缴不波及存活在通会话：挂断 hold 中的
         * 那路后系统 didDeactivate 可能迟到，而另一路 established 非
         * hold 正在跑音频——无条件放行会把活通话陪葬（didDeactivate
         * →unit STOPPED 无声）。存在实时音频需求（非终态 established
         * 且非 holdFlag）时不放行 deactivate，而是立即重建音频链：
         * 系统随 didDeactivate 已收走 AVAudioSession 本身并打断 audio
         * unit 底层 IO——翻转单元门强制重建（NO 停死 unit，其停用链会
         * 再 setActive:NO），setActive:YES 直接对 AVAudioSession 拿回
         * （RTCAudioSession 计数不知情系统侧收缴，经它转投可能空过，
         * lock 包裹保配置互斥），YES 重启 unit 重建 IO（重启边界的
         * applySpeakerCategoryAndOverride 双写顺带收口路由）。
         * 全部终结/仅 hold 时照常放行（hold 无声需求，didDeactivate
         * 正确，后续 resume 由 restoreAudioForResumingCall 补链），
         * 三条路径闭合 */
        if ([self hasLiveAudioDemand]) {
            rtcSession.isAudioEnabled = NO;
            NSError *activateError = nil;
            [rtcSession lockForConfiguration];
            BOOL reactivated = [[AVAudioSession sharedInstance]
                setActive:YES error:&activateError];
            [rtcSession unlockForConfiguration];
            if (!reactivated) {
                [self webrtcLog:@"[AUDIO] deactivate overridden, re-activate FAILED: %@",
                    activateError.localizedDescription ?: @"unknown error"];
            }
            rtcSession.isAudioEnabled = YES;
            [self webrtcLog:@"[AUDIO] deactivate overridden: audio unit rebuilt (live call keeps audio)"];
            return;
        }
        rtcSession.isAudioEnabled = NO;
        [self webrtcLog:@"[AUDIO] deactivate (didDeactivate -> disabled)"];
    }];
}

/* 是否存在实时音频需求——非终态、established 视图且非 holdFlag 的会话
 * （hold 会话 sendonly 无声需求）。与 hasEstablishedSession 的区别：
 * 后者供 currentAudioRoute 门控（hold 也算通话中），此处过滤 hold 只认
 * 真正在跑双向音频的会话。主线程限定（registry 契约） */
- (BOOL)hasLiveAudioDemand
{
    for (SipCallSession *session in [self.registry snapshot]) {
        if (session.isTerminal || session.holdFlag) {
            continue;
        }
        if ([session.callStateView isEqualToString:SipCallStateEstablished]
            || [session.callStateView isEqualToString:SipCallStateIncomingAnswered]) {
            return YES;
        }
    }
    return NO;
}

/* 多通挂断后的音频恢复：挂断在通那路时
 * 剩余的是 hold 会话（无声需求），系统 didDeactivate 正确、上面照关
 * 音频单元。但存活那路 resume 时 CallKit 不会再发 didActivate（激活
 * 只随接听/呼出动作来一次），激活链就此断掉——unhold 成功但无声；
 * AVAudioSession 失活同时 currentAudioRoute 的 isAudioEnabled 门恒关、
 * 真实路由读不出，扬声器按钮卡死在 fallback 快照（speakerOverride
 * 残留误报）。
 * resume 侧显式重激活：setActive:YES（系统停的要自己开回来）+
 * isAudioEnabled 开单元门，unit 重启后音频与路由快照一并恢复。
 * 主线程（holdInternal 调用链） */
- (void)restoreAudioForResumingCall:(SipCallSession *)session
{
    RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
    if (rtcSession.isAudioEnabled) {
        return;
    }
    NSError *activateError = nil;
    if (![rtcSession setActive:YES error:&activateError]) {
        [self webrtcLog:@"[AUDIO] resume-restore setActive FAILED: %@",
            activateError.localizedDescription ?: @"unknown error"];
        return;
    }
    rtcSession.isAudioEnabled = YES;
    [self webrtcLog:@"[AUDIO] resume-restore (call %ld, didDeactivate 后重激活)",
        (long)session.callId];
}

#pragma mark - 5s 音频激活兜底看门狗（主线程）

- (void)armAudioForceWatchdogForSession:(SipCallSession *)session
{
    if (_callKitCoordinator == nil || session == nil) {
        return;
    }
    [self cancelAudioForceWatchdog];
    _audioForceSessionId = session.sessionId;
    __weak SipWebrtcEngine *weakSelf = self;
    long long sid = session.sessionId;
    _audioForceWatchdog = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                         repeats:NO
                                                           block:^(NSTimer *timer) {
        SipWebrtcEngine *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [strongSelf audioForceWatchdogFiredForSessionId:sid];
    }];
}

- (void)cancelAudioForceWatchdog
{
    if (_audioForceWatchdog != nil) {
        [_audioForceWatchdog invalidate];
        _audioForceWatchdog = nil;
    }
    _audioForceSessionId = -1;
}

- (void)audioForceWatchdogFiredForSessionId:(long long)sessionId
{
    _audioForceWatchdog = nil;
    RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
    if (rtcSession.isAudioEnabled) {
        return;
    }
    /* 会话已终结（didActivate 未到且通话已挂）不强制启动音频 */
    SipCallSession *session = [self.registry sessionWithId:sessionId];
    BOOL established = NO;
    for (SipCallSession *s in [self.registry snapshot]) {
        if (!s.isTerminal
            && ([s.callStateView isEqualToString:SipCallStateEstablished]
                || [s.callStateView isEqualToString:SipCallStateIncomingAnswered])) {
            established = YES;
            break;
        }
    }
    if (session == nil || !established) {
        [self webrtcLog:@"[AUDIO] force-enable skipped: no established session"];
        return;
    }
    rtcSession.isAudioEnabled = YES;
    [self webrtcLog:@"[AUDIO] force-enable (didActivate 5s 未到，会话 %lld 通话中)",
        sessionId];
}

#pragma mark - ys 回调入口（主线程）

- (void)handleRegisterState:(int)accId status:(int)status text:(NSString *)text
{
    [self ysLog:@"reg acc=%d status=%d (%@)", accId, status, text];
    if (status == 200) {
        [self engineLog:@"registered OK"];
        /* 注册成功：撤注册监督（net-recovery 兜底若在监督中，一行日志
         * 收口；reg watch tick 的 lastRegStatus 判定由此同源） */
        [self stopRegWatch:YES];
        /* 注册成功：pending 来电卡片缩短撤销窗口（push 唤醒后 INVITE 下发
         * 窗口；主叫提前挂断的无 INVITE 来电及时收口） */
        [_callKitCoordinator onRegistered];
        /* 注册成功时序信号（主线程 post）：push 唤醒链据此撤头——
         * 重试期间粘性三头保留，重试 REGISTER 携带以完成 push 配对 */
        [[NSNotificationCenter defaultCenter]
            postNotificationName:SipWebrtcEngineDidRegisterOKNotification object:nil];
    }
    _lastRegText = text;
    _lastRegStatus = status;
    if (_callback) {
        [_callback onRegisterState:status text:text ?: @""];
    }
}

/* pjsua 呼叫状态 → 视图状态映射（安卓 postCallState:1085-1142 +
 * computeViewState:1291-1342） */
- (void)handleCallState:(int)callId state:(int)state lastStatus:(int)lastStatus
{
    [self.registry purgeExpiredNow];
    SipCallSession *session = [self.registry findByCallId:callId];
    if (session == nil) {
        /* 终态清除后迟到的重复事件，或引擎未跟踪的呼叫 */
        [self ysLog:@"call %d state=%@ last_code=%d (no session)",
            callId, [self.class callStateName:state], lastStatus];
        return;
    }
    [self ysLog:@"call %d state=%@ last_code=%d",
        callId, [self.class callStateName:state], lastStatus];

    session.pjsuaState = state;
    session.lastStatus = lastStatus;
    if (state == SipPjsuaStateConfirmed) {
        session.confirmedOnce = YES;
        if (session.callStartTime == 0) {
            session.callStartTime = SipCurrentTimeMillis();
        }
        /* 通话音频模式：iOS 无安卓 beginCommunicationMode 对应项——
         * AVAudioSession 已在 ensureWebRtc 固定 playAndRecord/voiceChat */
        /* 呼出腿 CallKit didActivate 5s 兜底 arm 点（来电梯腿在
         * sendAnswerWithLocalSdp 200 发出后 arm） */
        if (_callKitCoordinator != nil) {
            [self armAudioForceWatchdogForSession:session];
        }
    }

    NSString *view = [self computeViewState:session state:state lastStatus:lastStatus];
    if (view.length > 0 && ![view isEqualToString:session.callStateView]) {
        [self engineLog:@"call %d view %@ -> %@", callId, session.callStateView, view];
        session.callStateView = view;
        [self handleViewSideEffects:session view:view];
    }

    if (state == SipPjsuaStateDisconnected) {
        if (session.isTerminal) {
            [self onSessionTerminated:session];
        } else {
            /* 非映射终态兜底（理论不可达） */
            session.callStateView = SipCallStateTerminated;
            [self onSessionTerminated:session];
        }
    }
    [self notifySessionChanged:session];
}

/* 200 OK answer 到达（安卓 postAnswerSdp:1144-1172）：仅本地 offer
 * （INVITE/re-INVITE）在途时应用。每次 offer 都要应用其 answer，
 * 否则 PeerConnection 停在 have-local-offer，后续对端 offer 的
 * SRD 全被拒 */
- (void)handleAnswerSdp:(NSString *)sdp callId:(int)callId
{
    SipCallSession *session = [self.registry findByCallId:callId];
    if (session == nil || session.peerConnection == nil || !session.awaitingAnswer) {
        return;
    }
    session.awaitingAnswer = NO;
    [self ysLog:@"200 OK answer received (%lu bytes)", (unsigned long)sdp.length];
    /* 入口时钟归一（wire 8000 → webrtc 48000，呼出 200 OK 的 answer
     * SRD 同 answerRemoteOffer 的 offer 入口） */
    NSString *normalizedSdp = SipSdpTelephoneEventToWebRTC(sdp ?: @"");
    RTCSessionDescription *answer =
        [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer
                                                sdp:normalizedSdp];
    [session.peerConnection setRemoteDescription:answer
                               completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self webrtcLog:@"SetRemoteDescription: %@",
                error ? [NSString stringWithFormat:@"FAILED: %@",
                         error.localizedDescription] : @"OK"];
        });
    }];
}

/* 来电 INVITE（安卓 postIncomingSdp:1179-1222）：缓存 offer 与头
 * （C 字符串已在回调入口深拷贝为 NSString），置 IncomingTrying 等
 * callAnswer / callReject；振铃（pjsua 自动 180）经 handleCallState
 * → IncomingRinging */
- (void)handleIncomingSdp:(NSString *)sdp
                   callId:(int)callId
                requestId:(NSString *)requestId
             callerIdName:(NSString *)callerIdName
             remoteNumber:(NSString *)remoteNumber
{
    if ([self.registry findByCallId:callId] != nil) {
        [self ysLog:@"duplicate incoming event for call %d", callId];
        return;
    }
    SipCallSession *session =
        [self.registry createSessionWithDirection:SipCallDirectionIn];
    if (session == nil) {
        /* 容量满：直接 486，避免对端干等（JS 侧本就限制 2 路） */
        [self engineLog:@"incoming call %d dropped: MAX_CONCURRENT", callId];
        ys_reject_call(callId);
        return;
    }
    session.callId = callId;
    session.groupId = [NSString stringWithFormat:@"%d", callId];
    session.offerSdp = sdp ?: @"";
    session.requestId = requestId;
    session.callerIdName = callerIdName;
    session.accountName = callerIdName;
    session.remoteNumber = remoteNumber ?: @"";
    session.pjsuaState = SipPjsuaStateIncoming;
    session.callStateView = SipCallStateIncomingTrying;

    NSMutableString *detail = [NSMutableString stringWithFormat:
        @"incoming call %d (offer %lu bytes", callId,
        (unsigned long)session.offerSdp.length];
    if (requestId.length > 0) {
        [detail appendFormat:@", X-Request-ID=%@", requestId];
    }
    if (callerIdName.length > 0) {
        [detail appendFormat:@", X-Nov-Caller-ID-Name=%@", callerIdName];
    }
    [detail appendString:@") -> waiting for answer/reject"];
    [self ysLog:@"%@", detail];

    /* CallKit 模式：推送先行 report 的会话匹配（FIFO 号码命中复用 uuid）；
     * 未命中现场 report（无推送来电——服务器直接 INVITE）。本地铃声/
     * 振动改由系统卡片承担（双铃声冲突）；coordinator 未就绪（nil）
     * 时保留 SipRingtoneHelper + RN 弹屏（一阶段行为）。 */
    if (_callKitCoordinator != nil) {
        NSUUID *uuid = [_callKitCoordinator matchIncoming:session.remoteNumber];
        if (uuid == nil) {
            uuid = [_callKitCoordinator reportIncomingCall:nil
                                                 callerName:callerIdName
                                               callerNumber:remoteNumber];
        }
        session.callKitUuid = uuid;
        [_callKitCoordinator onSessionBound:uuid];
    } else {
        /* 来电铃声 + 振动（不摘麦克风；展示仲裁由上层 onIncomingCall 决定） */
        [SipRingtoneHelper playRingtone];
    }

    if (_callback) {
        [_callback onIncomingCall:[session toDictionary]];
    }
    [self notifySessionChanged:session];
}

/* re-INVITE（安卓 postReinviteSdp:1224-1270）：对端发起重协商
 * （hold/resume 等）。在途 answer / 本地 offer（glare）时丢弃等重传 */
- (void)handleReinviteSdp:(NSString *)sdp callId:(int)callId
{
    SipCallSession *session = [self.registry findByCallId:callId];
    if (session == nil || session.peerConnection == nil) {
        [self webrtcLog:@"re-INVITE but session/PeerConnection is gone"];
        return;
    }
    /* SBC 接通后 100ms 内连发两个 re-INVITE：第二个 offer 到达
     * 时前一个 answer 链可能仍在跑，新链的 answer 会撞上已被
     * 推进的 INVITE 状态（库层拒绝）——丢弃，对端收不到应答
     * 会重传 INVITE，届时链空闲再正常处理。 */
    if (session.answerPending && !session.answerSent) {
        [self webrtcLog:@"re-INVITE while previous answer in flight"
            @" - dropping, peer will retransmit"];
        return;
    }
    /* glare：本地 re-INVITE offer 在途（have-local-offer）时
     * SRD(offer) 会被 WebRTC 拒绝（wrong state）——同样丢弃等重传。 */
    if (session.awaitingAnswer) {
        [self webrtcLog:@"re-INVITE collides with our pending offer (glare)"
            @" - dropping, peer will retransmit"];
        return;
    }
    session.answerSent = NO;
    [self webrtcLog:@"re-INVITE offer (%lu bytes), renegotiating",
        (unsigned long)sdp.length];

    /* 对端 hold/resume 检测：offer 方向 sendonly/inactive = 对端保持；
     * sendrecv/缺省 = 恢复 */
    BOOL remoteHold = [self.class detectRemoteHold:sdp];
    if (remoteHold != session.remoteHoldFlag) {
        session.remoteHoldFlag = remoteHold;
        session.holdStartTime = remoteHold ? SipCurrentTimeMillis() : 0;
        [self webrtcLog:@"remote hold=%@ (call %d)",
            remoteHold ? @"YES" : @"NO", callId];
        [self notifySessionChanged:session];
    }

    [self answerRemoteOffer:session offerSdp:sdp ?: @""];
}

/* REFER 转接进度（安卓 postTransferState:878-899）：final 2xx =
 * 转接成功（对端已与新目标建立通话），本方自动挂断；final 非 2xx
 * 失败，保持通话状态由用户决定 */
- (void)handleTransferState:(int)callId status:(int)status isFinal:(BOOL)isFinal
{
    [self ysLog:@"transfer call %d status=%d%@", callId, status,
        isFinal ? @" (final)" : @""];
    SipCallSession *session = [self.registry findByCallId:callId];
    if (session == nil) {
        return;
    }
    if (isFinal) {
        if (status >= 200 && status < 300) {
            [self engineLog:@"transfer OK -> hanging up local leg"];
            [self callHangup:session.callId];
        } else {
            [self engineLog:@"transfer FAILED (%d), call kept", status];
            [self notifySessionChanged:session];
        }
    }
}

- (void)handleEngineLog:(int)level message:(NSString *)msg
{
    if (_callback) {
        [_callback onLog:level message:msg];
    }
}

#pragma mark - 视图状态映射（detail-design §1.x / 安卓 computeViewState）

/* pjsua state/last_status → 会话视图状态；返回 nil 表示保持当前视图
 * （CONNECTING 等过渡态） */
- (NSString *)computeViewState:(SipCallSession *)session
                         state:(int)state
                    lastStatus:(int)lastStatus
{
    switch (state) {
        case SipPjsuaStateCalling:
            return session.isIncoming ? SipCallStateIncomingTrying : SipCallStateTrying;
        case SipPjsuaStateEarly:
            /* 呼出 180/183+SDP → Ringing；来电 180（pjsua 自动发）→
             * IncomingRinging（canBeAnswered=true） */
            return session.isIncoming ? SipCallStateIncomingRinging : SipCallStateRinging;
        case SipPjsuaStateConnecting:
            /* 2xx 在途，CONFIRMED 紧随，不产生独立视图 */
            return nil;
        case SipPjsuaStateConfirmed:
            return session.isIncoming ? SipCallStateIncomingAnswered : SipCallStateEstablished;
        case SipPjsuaStateDisconnected:
            if (session.isIncoming) {
                if (session.rejectRequested) {
                    return SipCallStateIncomingRejected;
                }
                /* 接通过（CONFIRMED）或本端主动挂断 = 正常终结；
                 * 从未接通即断（对端 CANCEL / 超时）= 未接来电。
                 * 判据用事实标志而非 callStateView——后者被 callHangup
                 * 乐观置 Terminated 污染，会误判 Missed */
                if (session.confirmedOnce || session.hangupRequested) {
                    return SipCallStateTerminated;
                }
                return SipCallStateIncomingMissed;
            }
            /* 呼出终态按最后响应码分流 */
            if (lastStatus == 486 || lastStatus >= 600) {
                return SipCallStateBusy;
            }
            /* 401=未授权(凭证拒) 403=禁用 407=代理认证重试超限 */
            if (lastStatus == 401 || lastStatus == 403 || lastStatus == 407) {
                return SipCallStateUnauthorized;
            }
            if (lastStatus == 487) {
                /* 呼出取消（我方 CANCEL 后的最终响应） */
                return SipCallStateTerminated;
            }
            if (lastStatus >= 400 && lastStatus < 600) {
                return SipCallStateError;
            }
            return SipCallStateTerminated;
        default:
            return nil;
    }
}

/* 视图变化副作用的收口（回铃音控制等，安卓 handleViewSideEffects:1345-1354） */
- (void)handleViewSideEffects:(SipCallSession *)session view:(NSString *)view
{
    if (session.isIncoming) {
        return;
    }
    if ([view isEqualToString:SipCallStateRinging]) {
        /* CallKit 模式系统自带呼出回铃（含音频路由），本地回铃禁用防双声；
         * coordinator 未就绪（nil）时保留（一阶段行为） */
        if (_callKitCoordinator == nil) {
            [SipRingtoneHelper playBackTone];
        }
    } else if ([view isEqualToString:SipCallStateEstablished] || session.isTerminal) {
        [SipRingtoneHelper stopBackTone];
    }
}

/* 对端 offer 方向检测：sendonly/inactive = hold（安卓 detectRemoteHold:1357-1364） */
+ (BOOL)detectRemoteHold:(NSString *)sdp
{
    if (sdp.length == 0) {
        return NO;
    }
    /* 行级语义（"a=sendonly" 非 "a=sendonlyr" 之类误配）：SIP SDP 中
     * 属性均为完整行；直接子串判断已足够（demo 域无畸变 SDP） */
    return [sdp containsString:@"a=sendonly"] || [sdp containsString:@"a=inactive"];
}

/* SDP 候选过滤（呼出 INVITE / re-INVITE / answer 发送前统一走此函数；
 * 安卓 filterIpv6Candidates:2205 的对齐扩展——iOS WebRTC 全接口采集
 * host 候选（en0 + awdl 链路本地 + 蜂窝 × UDP/TCP），安卓仅在默认
 * 网络采集=单 UDP host。对 rtpengine（ICE-lite，按收包源地址 prflx
 * 学习）只有活跃接口的 UDP host 有意义：非活跃候选纯冗余，换网后旧
 * 接口残留候选还优先于新候选被 check（优先级未变）。三级过滤：
 *   1) IPv6 候选（v4 锚点对端不可达；address 字段——第 5 个空格分隔
 *      字段——含冒号即 IPv6）
 *   2) TCP 候选（passive host 无连接可能；配置层 tcpCandidatePolicy
 *      已禁，此处兜底）
 *   3) 收敛到活跃接口（netMonitor.activeIpv4 path 快照）单候选；无
 *      匹配（换网竞态：新接口候选未采出 / 无快照）保留全部 v4-UDP
 *      兜底，绝不产出零候选 SDP。mDNS .local 候选（不含冒号、非 IP）
 *      不等活跃地址，仅随兜底保留
 * 候选格式：a=candidate:<foundation> <component> <transport> <priority>
 * <address> <port> typ ... */
- (NSString *)filterSdpCandidates:(NSString *)sdp
{
    if (sdp.length == 0) {
        return sdp;
    }
    /* 出线时钟归一（webrtc 48000 → wire 8000，INVITE/answer/re-INVITE
     * 三路出口全经此，见 SipSdpTelephoneEventToWebRTC 注释） */
    NSString *normalized = SipSdpTelephoneEventToWire(sdp);
    NSString *activeIpv4 = self.netMonitor.activeIpv4;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSMutableArray<NSString *> *v4UdpCandidates = [NSMutableArray array];
    NSMutableArray<NSString *> *activeCandidates = [NSMutableArray array];
    /* 候选行收口槽位：首个候选行位置即收口点（候选行在 localDescription
     * 中连续；audio 单 m-line，收口必在原段内） */
    NSUInteger slot = NSNotFound;
    NSUInteger filteredCount = 0;
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"a=candidate:"]) {
            /* 对齐安卓 trim + \s+ 切分：先 trim 行、再按空白切并剔除空段 */
            NSMutableArray<NSString *> *fields = [NSMutableArray array];
            for (NSString *field in [trimmed componentsSeparatedByCharactersInSet:
                                     [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
                if (field.length > 0) {
                    [fields addObject:field];
                }
            }
            if (fields.count > 4 && [fields[4] containsString:@":"]) {
                filteredCount++;
                continue; /* 1) IPv6 候选行：丢弃 */
            }
            if (fields.count > 2
                && [fields[2] caseInsensitiveCompare:@"tcp"] == NSOrderedSame) {
                filteredCount++;
                continue; /* 2) TCP 候选行：丢弃 */
            }
            if (slot == NSNotFound) {
                slot = kept.count;
                [kept addObject:@""]; /* 槽位占位，收尾替换 */
            }
            [v4UdpCandidates addObject:line];
            if (activeIpv4.length > 0 && fields.count > 4
                && [fields[4] isEqualToString:activeIpv4]) {
                [activeCandidates addObject:line];
            }
            continue;
        }
        [kept addObject:line];
    }
    /* 3) 活跃接口收敛：命中才收；未命中（竞态/无快照）全保留兜底 */
    NSArray<NSString *> *chosen =
        (activeCandidates.count > 0) ? activeCandidates : v4UdpCandidates;
    if (slot != NSNotFound) {
        kept[slot] = [chosen componentsJoinedByString:@"\n"];
        [self webrtcLog:@"sdp candidates: %lu gathered -> %lu sent (active %@)",
            (unsigned long)(v4UdpCandidates.count + filteredCount),
            (unsigned long)chosen.count,
            activeIpv4.length > 0 ? activeIpv4 : @"n/a"];
    } else if (filteredCount > 0) {
        /* 全部候选被滤（纯 v6 网络等）：无槽位可收口，留痕供排障
         *（answer 侧由零候选预算保护收口，offer 侧纯信令降级） */
        [self webrtcLog:@"sdp candidates: %lu gathered -> 0 sent (all filtered)",
            (unsigned long)filteredCount];
    }
    return [kept componentsJoinedByString:@"\n"];
}

#pragma mark - WebRTC：PeerConnection 建立（安卓 setupPeerConnection:1405-1428）

- (void)setupPeerConnection:(SipCallSession *)session
{
    if (_factory == nil || session.peerConnection != nil) {
        return;
    }
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    /* 候选极简化（F4，对齐安卓 :1493-1498）：不配 STUN，仅收集 host 候选。
     * 旧结论"云媒体网关（公网 IP）只能回包到 srflx"被安卓上线实证推翻
     * ——rtpengine（ICE-lite）按收包源地址回包（prflx 学习），host 候选
     * 直发 check 即可达；srflx 在对称 NAT 下本就无效且引入 STUN 依赖的
     * 失败面与 gathering 延迟（150-800ms + 看门狗兜底，呼出延时主源
     * 之一）。网络切换恢复链同样走 prflx。stunServers 配置链（下发/
     * 解析/存储）保留但不用于候选收集——接口契约不变，服务器下发链
     * 零感知 */
    config.iceServers = @[];
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    /* 持续候选收集：换网后新接口的 host 候选持续产出并入后续 offer
     * （GATHER_ONCE 下新候选不出——网络切换媒体恢复链的前提，安卓同
     * 配置 hold/resume 已上线实证）。发送不依赖 COMPLETE——iOS 此 SDK
     * 下该状态永不到达（见 gather 看门狗双窗注释），候选 150ms 落盘
     * 窗即发 */
    config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    /* TCP 候选禁用（源层面不建 TCP 端口）：rtpengine 按收包源地址学习
     * 走 UDP，TCP host（passive）无连接可能，纯 gather 噪声与 socket
     * 浪费；SDP 过滤层（filterSdpCandidates）再兜底 */
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;

    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                             optionalConstraints:nil];
    session.peerConnection =
        [_factory peerConnectionWithConfiguration:config
                                       constraints:constraints
                                          delegate:self];
    if (session.peerConnection == nil) {
        [self webrtcLog:@"PeerConnection create FAILED"];
        return;
    }
    session.audioSource = [_factory audioSourceWithConstraints:nil];
    session.audioTrack = [_factory audioTrackWithSource:session.audioSource
                                                trackId:[NSString
                                                    stringWithFormat:@"pjsua-audio-%lld",
                                                    session.sessionId]];
    [session.peerConnection addTrack:session.audioTrack
                           streamIds:@[[NSString
                               stringWithFormat:@"pjsua-stream-%lld",
                               session.sessionId]]];
    [self applyTrackEnabled:session];
}

/* track 使能 = !mute && !hold（静音与保持都关本地发送） */
- (void)applyTrackEnabled:(SipCallSession *)session
{
    if (session.audioTrack != nil) {
        session.audioTrack.isEnabled = (!session.muteFlag && !session.holdFlag);
    }
}

/* hold 方向语义（RFC 3264 §8.4 单边 hold，安卓 applyTransceiverDirection:971-985）：
 * hold = 我方 offer sendonly；resume = sendrecv。track.isEnabled 只控
 * 数据发送、不改变 SDP 方向：m 行方向由 transceiver.direction 决定，
 * 不显式设置时 createOffer 恒 sendrecv——hold 对对端完全不可见（实测教训） */
- (void)applyTransceiverDirection:(SipCallSession *)session held:(BOOL)held
{
    if (session.peerConnection == nil) {
        return;
    }
    RTCRtpTransceiverDirection direction = held
        ? RTCRtpTransceiverDirectionSendOnly
        : RTCRtpTransceiverDirectionSendRecv;
    for (RTCRtpTransceiver *t in session.peerConnection.transceivers) {
        NSError *error = nil;
        [t setDirection:direction error:&error];
        if (error != nil) {
            [self webrtcLog:@"setDirection failed: %@", error.localizedDescription];
        }
    }
}

#pragma mark - 呼出链主体（安卓 startOutgoingCall:491-536）

- (void)startOutgoingCall:(SipCallSession *)session
{
    if (session.isTerminal) {
        return;
    }
    /* X-Request-ID 不在此设置（呼出发起时）：该头为全局一次性消费，
     * 两路呼出 gather 窗口重叠时后设者覆盖先设者，先提交的 INVITE 会
     * 带上别人的 requestId（实测串号）——改在
     * sendInviteWithLocalSdp 提交时用本会话 requestId 设置 */
    [self setupPeerConnection:session];
    if (session.peerConnection == nil) {
        [self engineLog:@"WebRTC unavailable - cannot dial"];
        [self terminateSession:session view:SipCallStateError];
        return;
    }

    /* 编码偏好须在 createOffer 前落定（配置∩支持交集，空则兜底全 4，
     * 见 applyCodecPreferencesForOffer） */
    [self applyCodecPreferencesForOffer:session];

    /* 完成块按 sessionId 回查会话（registry 主线程持有；避免
     * session→pc→block→session 强引用环，且终态滞留后自然失效） */
    long long sid = session.sessionId;
    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:
            @{kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue}
                                                 optionalConstraints:nil];
    [session.peerConnection offerForConstraints:constraints
                              completionHandler:^(RTCSessionDescription *sdp,
                                                  NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SipCallSession *s = [self.registry sessionWithId:sid];
            if (error != nil) {
                [self webrtcLog:@"CreateOffer FAILED: %@", error.localizedDescription];
                if (s != nil && !s.isTerminal) {
                    [self terminateSession:s view:SipCallStateError];
                }
                return;
            }
            if (s == nil || s.peerConnection == nil) {
                return;
            }
            [self webrtcLog:@"offer generated (%lu bytes)", (unsigned long)sdp.sdp.length];
            [s.peerConnection setLocalDescription:sdp
                                  completionHandler:^(NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SipCallSession *s2 = [self.registry sessionWithId:sid];
                    if (err != nil) {
                        [self webrtcLog:@"SetLocalDescription: %@",
                            err.localizedDescription];
                        return;
                    }
                    if (s2 == nil || s2.peerConnection == nil || s2.isTerminal) {
                        return;
                    }
                    [self webrtcLog:@"SetLocalDescription: OK"];
                    /* SLD 触发 gathering：候选逐个回调重挂看门狗；
                     * COMPLETE 或看门狗到点即发 INVITE */
                    [self armGatherWatchdog:s2];
                    if (s2.peerConnection.iceGatheringState
                        == RTCIceGatheringStateComplete) {
                        [self sendInviteWithLocalSdp:s2];
                    }
                });
            }];
        });
    }];

    [self webrtcLog:@"PeerConnection created -> %@", session.remoteNumber];
}

/* localDescription 含全部候选（或看门狗到点带已有候选）→ 发 INVITE
 * （安卓 sendInviteWithLocalSdp:1442-1466） */
- (void)sendInviteWithLocalSdp:(SipCallSession *)session
{
    if (session.inviteSent || session.peerConnection == nil || session.isTerminal) {
        return;
    }
    RTCSessionDescription *desc = session.peerConnection.localDescription;
    if (desc == nil) {
        return;
    }
    session.inviteSent = YES;

    /* X-Request-ID 在 INVITE 提交时设置（时机论证见 startOutgoingCall
     * 注释）：一次性消费，紧接着的 ys_make_call_with_sdp 即携带并清除 */
    if (session.requestId.length > 0) {
        NSString *header = [NSString stringWithFormat:@"X-Request-ID: %@",
                            session.requestId];
        if (ys_set_outgoing_invite_headers(header.UTF8String) != 0) {
            [self ysLog:@"ys_set_outgoing_invite_headers failed"];
        }
    }

    pjsua_call_id newCallId = -1;
    /* 候选过滤：IPv6/TCP 滤除 + 收敛活跃接口单候选（见 filterSdpCandidates） */
    NSString *offerSdp = [self filterSdpCandidates:desc.sdp];
    int rc = ys_make_call_with_sdp(_accId,
                                   session.remoteNumber.UTF8String ?: "",
                                   offerSdp.UTF8String ?: "",
                                   &newCallId);
    if (rc != 0 || newCallId < 0) {
        [self ysLog:@"ys_make_call_with_sdp failed"];
        /* 提交失败头未消费会残留到下一路 INVITE（串号），显式清除 */
        ys_set_outgoing_invite_headers(NULL);
        [self terminateSession:session view:SipCallStateError];
        return;
    }
    session.callId = newCallId;
    /* groupId 不改写：保持 sessionId 稳定语义（见 callMake 注释） */
    session.awaitingAnswer = YES;
    session.callStateView = SipCallStateTrying;  /* make_call 提交成功 */
    [self ysLog:@"INVITE sent (call %ld, offer %lu bytes)",
        (long)session.callId, (unsigned long)offerSdp.length];
    [self notifySessionChanged:session];
}

#pragma mark - offer→answer 链（来电接听与 re-INVITE 共用，安卓 :1475-1564）

/* SRD(offer) → createAnswer → SLD → answerPending=true → 等 ICE
 * （gathering complete 或看门狗）→ 200（answer 必须携带候选，
 * 服务器非 trickle，故 SLD 后不能立即发 200）。 */
- (void)answerRemoteOffer:(SipCallSession *)session offerSdp:(NSString *)offerSdp
{
    if (session.peerConnection == nil) {
        return;
    }
    long long sid = session.sessionId;
    /* 入口时钟归一（wire 8000 → webrtc 48000，SRD 前归一使 capability
     * 匹配成功，answer 才能带 telephone-event） */
    NSString *wireSdp = SipSdpTelephoneEventToWebRTC(offerSdp ?: @"");
    RTCSessionDescription *offer =
        [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:wireSdp];
    [session.peerConnection setRemoteDescription:offer
                                completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SipCallSession *s = [self.registry sessionWithId:sid];
            if (s == nil || s.peerConnection == nil) {
                return;
            }
            if (error != nil) {
                [self webrtcLog:@"SetRemoteDescription: FAILED: %@",
                    error.localizedDescription];
                /* offer 不可应答（如缺 DTLS fingerprint，服务器侧媒体
                 * 配置问题）：立即 486 终结来电并转拒接终态。否则 200
                 * 永不发、对端超时取消（603），JS 接听乐观态收到 Missed
                 * 的非法序列会导致通话导航栈异常（实测白屏） */
                if (s.isIncoming && !s.isTerminal
                    && (s.pjsuaState == SipPjsuaStateIncoming
                        || s.pjsuaState == SipPjsuaStateEarly)) {
                    [self engineLog:@"incoming offer unacceptable -> reject 486"];
                    ys_reject_call((pjsua_call_id)s.callId);
                    /* 事实标志：DISCONNECTED 重算时仍归 IncomingRejected，
                     * 否则 view 历史判据会把已置的拒接态翻成 Missed */
                    s.rejectRequested = YES;
                    s.callStateView = SipCallStateIncomingRejected;
                    [self onSessionTerminated:s];
                    [self notifySessionChanged:s];
                }
                return;
            }
            [self webrtcLog:@"SetRemoteDescription: OK"];
            /* 编码偏好须在 createAnswer 前落定（offer∩配置∩支持；
             * 空交集不设偏好——协商自然失败语义） */
            [self applyCodecPreferencesForAnswer:s offerSdp:offer.sdp];
            RTCMediaConstraints *constraints =
                [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                                     optionalConstraints:nil];
            [s.peerConnection answerForConstraints:constraints
                                  completionHandler:^(RTCSessionDescription *answer,
                                                      NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SipCallSession *s2 = [self.registry sessionWithId:sid];
                    if (s2 == nil || s2.peerConnection == nil) {
                        return;
                    }
                    if (err != nil) {
                        [self webrtcLog:@"CreateAnswer FAILED: %@",
                            err.localizedDescription];
                        return;
                    }
                    [s2.peerConnection setLocalDescription:answer
                                          completionHandler:^(NSError *err2) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            SipCallSession *s3 = [self.registry sessionWithId:sid];
                            if (s3 == nil || s3.peerConnection == nil) {
                                return;
                            }
                            if (err2 != nil) {
                                [self webrtcLog:@"SetLocalDescription FAILED: %@",
                                    err2.localizedDescription];
                                return;
                            }
                            if (s3.isTerminal) {
                                return;
                            }
                            s3.answerPending = YES;
                            [self webrtcLog:@"answer set locally, "
                                @"gathering ICE candidates..."];
                            [self armGatherWatchdog:s3];
                            /* gathering 可能已完成（re-INVITE 复用已收
                             * 集候选）-> 立即发 */
                            if (s3.peerConnection.iceGatheringState
                                == RTCIceGatheringStateComplete) {
                                [self sendAnswerWithLocalSdp:s3];
                            }
                        });
                    }];
                });
            }];
        });
    }];
}

/* 用本地 answer（含已收集候选）发 200（安卓 sendAnswerWithLocalSdp:1546-1564） */
- (void)sendAnswerWithLocalSdp:(SipCallSession *)session
{
    if (session.answerSent || !session.answerPending || session.peerConnection == nil
        || session.isTerminal) {
        return;
    }
    RTCSessionDescription *desc = session.peerConnection.localDescription;
    if (desc == nil) {
        return;
    }
    /* 候选过滤（同 INVITE / re-INVITE，见 filterSdpCandidates） */
    NSString *answerSdp = [self filterSdpCandidates:desc.sdp];

    /* 呼入初始应答零候选保护（安卓 ZERO_CANDIDATE_BUDGET_MS，见常量区
     * 注释）：仅 INCOMING/EARLY 窗口生效（re-INVITE 应答走本方法时为
     * CONFIRMED 态，复用已收集候选，天然排除——安卓
     * isIncomingInitialAnswer 同构判定）。判定用过滤后的 SDP：三级过滤
     * 后仍零候选才构成"发出即零候选"。预算内重臂看门狗周期重查（候选
     * 到达经落盘窗/COMPLETE 正常链回此处）；超预算收口终结，不发无声
     * 200（收口模板同 SRD 失败分支：事实标志防终态覆写） */
    if ((session.pjsuaState == SipPjsuaStateIncoming
         || session.pjsuaState == SipPjsuaStateEarly)
        && [answerSdp containsString:@"a=candidate"] == NO) {
        long long sid = session.sessionId;
        long long now = SipCurrentTimeMillis();
        if (self.zeroCandidateSinceMs == nil) {
            self.zeroCandidateSinceMs = [NSMutableDictionary dictionary];
        }
        NSNumber *since = self.zeroCandidateSinceMs[@(sid)];
        if (since == nil) {
            since = @(now);
            self.zeroCandidateSinceMs[@(sid)] = since;
        }
        if (now - since.longLongValue < kZeroCandidateBudgetMs) {
            /* 告警仅零候选持续超过落盘窗后打：候选并入 description 文本
             * 滞后于回调数十 ms，首查落在该窗口属正常时序（安卓同款） */
            if (now - since.longLongValue
                >= (long long)(kSipCandidateFlushSec * 1000.0)) {
                [self webrtcLog:@"answer 零候选，延长等待收集 (call %ld)",
                    (long)session.callId];
            }
            [self armGatherWatchdog:session];
            return;
        }
        [self.zeroCandidateSinceMs removeObjectForKey:@(sid)];
        if (session.answerRequested) {
            [self engineLog:@"answer 零候选超预算但用户已接听 "
                @"-> hangup (call %ld)", (long)session.callId];
            if (session.callId >= 0) {
                ys_hangup_call((pjsua_call_id)session.callId);
            }
            session.hangupRequested = YES;
            session.callStateView = SipCallStateTerminated;
        } else {
            [self engineLog:@"answer 零候选超预算 -> reject 486 (call %ld)",
                (long)session.callId];
            ys_reject_call((pjsua_call_id)session.callId);
            session.rejectRequested = YES;
            session.callStateView = SipCallStateIncomingRejected;
        }
        [self onSessionTerminated:session];
        [self notifySessionChanged:session];
        return;
    }
    [self.zeroCandidateSinceMs removeObjectForKey:@(session.sessionId)];
    session.answerSent = YES;
    [self cancelGatherWatchdog:session];

    if (ys_answer_call_with_sdp((pjsua_call_id)session.callId, 200,
                                answerSdp.UTF8String ?: "") == 0) {
        [self ysLog:@"answered 200 (call %ld, answer %lu bytes, ICE candidates included)",
            (long)session.callId, (unsigned long)answerSdp.length];
        if (session.isIncoming) {
            /* CallKit：200 已发——fulfill 挂起的接听动作（防系统 UI 先行
             * 显示接通而媒体未立）。re-INVITE 应答复用本方法时 uuid 下
             * 已无挂起动作，幂等无副作用 */
            if (session.callKitUuid != nil && _callKitCoordinator != nil) {
                [_callKitCoordinator onAnswerSentForUuid:session.callKitUuid];
            }
            /* didActivate 5s 未到的音频兜底（CallKit 激活线丢失时强制启
             * 动音频单元，保语音可用性优先） */
            [self armAudioForceWatchdogForSession:session];
        }
    } else {
        [self ysLog:@"answer FAILED"];
        if (session.isIncoming) {
            /* 200 发出失败：fail 挂起接听动作 + 保护性 486 收口
             * （终态 reportCallEnded(.failed) 由 onSessionTerminated 驱动） */
            if (session.callKitUuid != nil && _callKitCoordinator != nil) {
                [_callKitCoordinator onAnswerFailedForUuid:session.callKitUuid];
            }
            session.rejectRequested = YES;
            ys_reject_call((pjsua_call_id)session.callId);
        }
    }
}

#pragma mark - hold/resume re-INVITE 链（安卓 renegotiate:1571-1635）

- (void)renegotiate:(SipCallSession *)session
{
    if (session.peerConnection == nil) {
        return;
    }
    /* re-INVITE 属主叫侧 offer：每次刷新编码偏好（配置运行时变更后的
     * 新表下次 re-INVITE 自然生效） */
    [self applyCodecPreferencesForOffer:session];
    long long sid = session.sessionId;
    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                             optionalConstraints:nil];
    [session.peerConnection offerForConstraints:constraints
                              completionHandler:^(RTCSessionDescription *sdp,
                                                  NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SipCallSession *s = [self.registry sessionWithId:sid];
            if (s == nil || s.peerConnection == nil) {
                return;
            }
            if (error != nil) {
                [self webrtcLog:@"CreateOffer FAILED: %@", error.localizedDescription];
                s.reinvitePending = NO;
                return;
            }
            [self webrtcLog:@"hold/resume offer generated (%lu bytes)",
                (unsigned long)sdp.sdp.length];
            [s.peerConnection setLocalDescription:sdp
                                  completionHandler:^(NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SipCallSession *s2 = [self.registry sessionWithId:sid];
                    if (s2 == nil || s2.peerConnection == nil) {
                        return;
                    }
                    if (err != nil) {
                        [self webrtcLog:@"SetLocalDescription FAILED: %@",
                            err.localizedDescription];
                        s2.reinvitePending = NO;
                        return;
                    }
                    if (s2.isTerminal) {
                        return;
                    }
                    s2.reinvitePending = YES;
                    [self webrtcLog:@"hold/resume offer set, "
                        @"gathering ICE candidates..."];
                    [self armGatherWatchdog:s2];
                    /* re-INVITE 复用已收集候选时 gathering 已完成，立即发 */
                    if (s2.peerConnection.iceGatheringState
                        == RTCIceGatheringStateComplete) {
                        [self sendReinviteWithLocalSdp:s2];
                    }
                });
            }];
        });
    }];
}

/* 用本地 offer（含已收集候选）发 re-INVITE（安卓 sendReinviteWithLocalSdp:1617-1635） */
- (void)sendReinviteWithLocalSdp:(SipCallSession *)session
{
    if (!session.reinvitePending || session.peerConnection == nil || session.isTerminal) {
        return;
    }
    RTCSessionDescription *desc = session.peerConnection.localDescription;
    if (desc == nil) {
        return;
    }
    session.reinvitePending = NO;
    [self cancelGatherWatchdog:session];

    /* 候选过滤（同 INVITE / answer，见 filterSdpCandidates） */
    NSString *reinviteSdp = [self filterSdpCandidates:desc.sdp];
    if (ys_reinvite_with_sdp((pjsua_call_id)session.callId,
                             reinviteSdp.UTF8String ?: "") == 0) {
        session.awaitingAnswer = YES;
        [self ysLog:@"re-INVITE sent (call %ld, offer %lu bytes)",
            (long)session.callId, (unsigned long)reinviteSdp.length];
    } else {
        [self ysLog:@"re-INVITE FAILED"];
    }
}

#pragma mark - hold/resume（安卓 holdInternal:924-959）

- (void)holdInternal:(SipCallSession *)session held:(BOOL)held
{
    if (held) {
        /* 本地 offer 在途时 renegotiate 的 CreateOffer 会被 WebRTC 拒绝
         * （have-local-offer），先等上一个 offer 被 answer */
        if (session.awaitingAnswer) {
            [self engineLog:@"previous offer not answered yet - hold later"];
            return;
        }
        if (session.holdFlag) {
            [self engineLog:@"already on hold"];
            return;
        }
        session.holdFlag = YES;
        session.holdStartTime = SipCurrentTimeMillis();
        [self applyTrackEnabled:session];
        [self applyTransceiverDirection:session held:YES];
        [self webrtcLog:@"holding call %ld (sendonly offer)", (long)session.callId];
        [self renegotiate:session];
    } else {
        if (session.awaitingAnswer) {
            [self engineLog:@"previous offer not answered yet - resume later"];
            return;
        }
        if (!session.holdFlag) {
            [self engineLog:@"not on hold"];
            return;
        }
        session.holdFlag = NO;
        session.holdStartTime = 0;
        /* resume 先于 re-INVITE 重激活音频：didDeactivate 后 CallKit 不
         * 再发 didActivate，见 restoreAudioForResumingCall 注释 */
        [self restoreAudioForResumingCall:session];
        [self applyTrackEnabled:session];
        [self applyTransceiverDirection:session held:NO];
        [self webrtcLog:@"resuming call %ld (sendrecv offer)", (long)session.callId];
        [self renegotiate:session];
    }
    [self notifySessionChanged:session];
}

#pragma mark - ICE gathering 看门狗（每会话独立，主线程，安卓 :1641-1683）

- (void)armGatherWatchdog:(SipCallSession *)session
{
    [self armGatherWatchdog:session afterSec:kSipGatherWatchdogSec];
}

- (void)armGatherWatchdog:(SipCallSession *)session afterSec:(NSTimeInterval)sec
{
    [self cancelGatherWatchdog:session];
    long long sid = session.sessionId;
    /* gathering 窗口起点（[webrtc] gather complete 计时，AC-6 呼出延时
     * 量化点）：仅首轮写入——didGenerateIceCandidate 每候选重挂本方法
     * 不得重置起点。COMPLETE 点读出打日志，看门狗到点/会话释放时清除
     * （见三处消费点） */
    if (self.gatherStartTimes == nil) {
        self.gatherStartTimes = [NSMutableDictionary dictionary];
    }
    if (self.gatherStartTimes[@(sid)] == nil) {
        self.gatherStartTimes[@(sid)] = @(SipCurrentTimeMillis());
    }
    __weak SipWebrtcEngine *weakSelf = self;
    session.gatherWatchdog =
        [NSTimer scheduledTimerWithTimeInterval:sec
                                         repeats:NO
                                           block:^(NSTimer *timer) {
        [weakSelf gatherWatchdogFiredForSessionId:sid];
    }];
}

- (void)cancelGatherWatchdog:(SipCallSession *)session
{
    if (session.gatherWatchdog) {
        [session.gatherWatchdog invalidate];
        session.gatherWatchdog = nil;
    }
}

- (void)gatherWatchdogFiredForSessionId:(long long)sessionId
{
    SipCallSession *session = [self.registry sessionWithId:sessionId];
    if (session == nil) {
        return;
    }
    session.gatherWatchdog = nil;
    /* gather 窗口收口（未到 COMPLETE，不计 gather complete 耗时日志） */
    [self.gatherStartTimes removeObjectForKey:@(sessionId)];
    if (session.peerConnection == nil) {
        return;
    }
    if (session.answerPending) {
        if (!session.answerSent) {
            [self webrtcLog:@"gathering watchdog fired -> answer 200 (call %ld)",
                (long)session.callId];
            [self sendAnswerWithLocalSdp:session];
        }
        return;
    }
    if (session.reinvitePending) {
        [self webrtcLog:@"gathering watchdog fired -> re-INVITE (call %ld)",
            (long)session.callId];
        [self sendReinviteWithLocalSdp:session];
        return;
    }
    if (!session.inviteSent && !session.isIncoming) {
        [self webrtcLog:@"gathering watchdog fired -> INVITE"];
        [self sendInviteWithLocalSdp:session];
    }
}

#pragma mark - 网络切换恢复（10-20-ios-call-continuity，对齐安卓 :1809-2032）

/*
 * 链路：SipNetworkMonitor 换网事件（已防抖，主线程）→ ys_handle_ip_change
 * 启动库层信令恢复（shutdown 死连接 + 账号 re-REGISTER + 通话 dialog 换
 * transport）→ SHUTDOWN_TP 步完成即媒体恢复（不等 re-REGISTER 200——
 * 服务器对新连接的响应慢，等它会把媒体恢复拖到 32s+；注册由 reg watch
 * 兜底）→ 同凭据 re-INVITE（ufrag 不变 + GATHER_CONTINUALLY 持续产出
 * 的新候选，ICE/DTLS 状态延续媒体无缝）→ answer 经现有 handleAnswerSdp
 * 链应用。失败不挂断不重拨（R4：维持无声，ICE FAILED 挂断兜底）。
 * 状态字段（netRecoveryRunning / pendingRerun / regWatch 系列 /
 * lastRegStatus）全部仅主线程读写（引擎线程纪律，与安卓主线程
 * Handler 同构）。
 */

/* SipNetworkMonitor 换网事件落点（主线程，已防抖、key 已变化） */
- (void)handleNetworkChanged:(NSString *)reason
{
    if (!_started) {
        /* 引擎未启动：忽略（未注册监听也基本不会来——双保险，对齐安卓） */
        return;
    }
    if (_netRecoveryRunning) {
        /* 单飞：本轮进行中，标记重跑（双网竞态残余连发合并为下一轮，
         * 避免恢复风暴） */
        _netRecoveryPendingRerun = YES;
        [self webrtcLog:@"[net-recovery] cycle running, rerun flagged: %@", reason];
        return;
    }
    _netRecoveryRunning = YES;
    _netRecoveryPendingRerun = NO;
    _netRecoveryStartMs = SipCurrentTimeMillis();

    int active = 0;
    for (SipCallSession *session in [self.registry snapshot]) {
        if (session.callId >= 0
            && session.pjsuaState == SipPjsuaStateConfirmed
            && !session.isTerminal) {
            active++;
        }
    }
    [self webrtcLog:@"[net-recovery] trigger: %@, confirmed calls=%d", reason, active];

    if (ys_handle_ip_change() != 0) {
        /* 状态机启动失败（上游 ip_change 在途等）：本轮收尾（对齐安卓） */
        [self webrtcLog:@"[net-recovery] ys_handle_ip_change FAILED, abort"];
        [self finishNetRecoveryCycle];
        return;
    }
    [self armIpChangeWatchdog];
}

/* ys_ip_change_progress 落点（主线程，经 ys_engine_on_ip_change_progress
 * 桥接自 worker 线程）：step==SHUTDOWN_TP（死连接已淘汰，新请求自动走
 * 新连接）即进媒体恢复；COMPLETED（全链完成）同样收尾；其余 step 仅
 * 日志。reg watch 周期触发的 ip_change 不在恢复周期内（no cycle），
 * 仅日志——监督本身即信令侧动作，无媒体恢复语义 */
- (void)handleIpChangeProgress:(int)step status:(int)status
{
    if (!_netRecoveryRunning) {
        /* 无恢复周期在途（超时已收尾/reg watch 周期）：仅日志 */
        [self webrtcLog:@"[net-recovery] ip-change step %d (no cycle, ignored)", step];
        return;
    }
    [self webrtcLog:@"[net-recovery] ip-change step %d%@", step,
        status == 0 ? @"" : [NSString stringWithFormat:@" status=%d", status]];
    if (step == kPjsuaIpChangeOpShutdownTp || step == kPjsuaIpChangeOpCompleted) {
        [self cancelIpChangeWatchdog];
        [self onIpChangeCompleted:NO];
    }
}

- (void)armIpChangeWatchdog
{
    [self cancelIpChangeWatchdog];
    __weak SipWebrtcEngine *weakSelf = self;
    _ipChangeWatchdog = [NSTimer scheduledTimerWithTimeInterval:kNetRecoveryIpChangeTimeoutSec
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        SipWebrtcEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_ipChangeWatchdog = nil;
        [strongSelf onIpChangeCompleted:YES];
    }];
}

- (void)cancelIpChangeWatchdog
{
    if (_ipChangeWatchdog != nil) {
        [_ipChangeWatchdog invalidate];
        _ipChangeWatchdog = nil;
    }
}

/* 库层信令恢复收尾（SHUTDOWN_TP/COMPLETED 回调或 5s 看门狗）：进媒体
 * 恢复（幂等：netRecoveryRunning 撤除前的唯一入口） */
- (void)onIpChangeCompleted:(BOOL)timeout
{
    if (!_netRecoveryRunning) {
        return;
    }
    if (timeout) {
        [self webrtcLog:@"[net-recovery] ip-change DONE timeout (%.0fms), "
            @"continuing with completed steps (reg self-heal continues)",
            kNetRecoveryIpChangeTimeoutSec * 1000.0];
    } else {
        [self webrtcLog:@"[net-recovery] ip-change done (signal %lldms)",
            SipCurrentTimeMillis() - _netRecoveryStartMs];
    }
    [self runMediaRecovery];
}

/* 对全部 CONFIRMED 且非终态会话逐路发起同凭据 re-INVITE（媒体恢复） */
- (void)runMediaRecovery
{
    int restarted = 0;
    for (SipCallSession *session in [self.registry snapshot]) {
        if (session.callId < 0 || session.peerConnection == nil
            || session.isTerminal) {
            continue;
        }
        if (session.pjsuaState != SipPjsuaStateConfirmed) {
            continue;
        }
        [self recoverMediaForSession:session];
        restarted++;
    }
    [self webrtcLog:@"[net-recovery] media recovery started for %d call(s)", restarted];
    [self finishNetRecoveryCycle];
}

/* 单路媒体恢复：现有 renegotiate: 链原样复用（createOffer 空约束不设
 * IceRestart——ufrag 不变 + 新候选 = 同凭据 re-INVITE，对端不视为 ICE
 * restart，ICE/DTLS 延续；hold 中通话 transceiver 方向由 holdFlag 保持，
 * offer 天然 sendonly）。在途 offer 时跳过本路——对端 offer 若在途，
 * 其 answer 链会自然处理新候选（glare 防护用现有字段）。单路失败
 * （createOffer error / tsx 408/488/491）由 renegotiate 链内失败分支
 * 收尾（reinvitePending=NO），编排不额外挂断——维持无声，R4 语义 */
- (void)recoverMediaForSession:(SipCallSession *)session
{
    if (session.awaitingAnswer || session.reinvitePending) {
        [self webrtcLog:@"[net-recovery] call %ld skip: offer in flight (glare-safe)",
            (long)session.callId];
        return;
    }
    [self webrtcLog:@"[net-recovery] recover call=%ld: "
        @"same-credentials re-INVITE with fresh candidates",
        (long)session.callId];
    [self renegotiate:session];
}

/* 恢复周期收尾：计时日志 + pendingRerun 检查（竞态残余再走一轮）+
 * reg watch 启动 */
- (void)finishNetRecoveryCycle
{
    [self webrtcLog:@"[net-recovery] cycle done (%lldms)",
        SipCurrentTimeMillis() - _netRecoveryStartMs];
    _netRecoveryRunning = NO;
    if (_netRecoveryPendingRerun && _started) {
        _netRecoveryPendingRerun = NO;
        [self handleNetworkChanged:@"rerun"];
        return;
    }
    /* 恢复完成后注册仍未成功的（服务器半开连接占位场景）：启动注册
     * 监督，周期强制换连接重试 */
    [self startRegWatchIfNeeded];
}

/* F6 回前台补判入口（SceneDelegate sceneWillEnterForeground → 此处）：
 * 挂起期 NWPathMonitor 事件不送达（iOS 特有缺口 E13），回前台强制刷新
 * 快照补判——判定收敛在 SipNetworkMonitor 单点（与主链共用），换网才
 * 走恢复链，幂等 */
- (void)checkNetworkOnForeground
{
    [self.netMonitor checkNowOnForeground];
}

/* ---------------- 注册监督（恢复兜底） ---------------- */

/* 恢复周期结束后启动监督：第一拍（间隔后）判断注册状态——切换触发的
 * re-REGISTER 若仍在途（最长 32s tsx 超时），届时已终结，lastRegStatus
 * 准确；已 200 则监督自然结束（注册 200 的撤拍在 handleRegisterState）。
 * 已在监督则跳过 */
- (void)startRegWatchIfNeeded
{
    if (!_started || _regWatchActive) {
        return;
    }
    _regWatchActive = YES;
    _regWatchAttempts = 0;
    [self webrtcLog:@"[net-recovery] reg watch armed (check in %.0fs, retry up to %d attempts)",
        kRegWatchIntervalSec, kRegWatchMaxAttempts];
    [self scheduleRegWatchTick];
}

- (void)scheduleRegWatchTick
{
    __weak SipWebrtcEngine *weakSelf = self;
    _regWatchTimer = [NSTimer scheduledTimerWithTimeInterval:kRegWatchIntervalSec
                                                    repeats:NO
                                                      block:^(NSTimer *timer) {
        SipWebrtcEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf regWatchTickFired];
    }];
}

- (void)regWatchTickFired
{
    _regWatchTimer = nil;
    if (!_started || _lastRegStatus == 200) {
        _regWatchActive = NO;
        return; /* 已成功或引擎已停：监督自然结束 */
    }
    /* 恢复周期进行中：顺延一拍，避免 ip_change 状态机重叠 */
    if (_netRecoveryRunning) {
        [self webrtcLog:@"[net-recovery] reg watch deferred, recovery running"];
        [self scheduleRegWatchTick];
        return;
    }
    _regWatchAttempts++;
    if (_regWatchAttempts > kRegWatchMaxAttempts) {
        [self webrtcLog:@"[net-recovery] reg watch gave up after %d attempts, "
            @"leaving to reg refresh/user", kRegWatchMaxAttempts];
        _regWatchActive = NO;
        return;
    }
    [self webrtcLog:@"[net-recovery] reg watch attempt %d/%d: "
        @"ip-change cycle (force new connection)",
        _regWatchAttempts, kRegWatchMaxAttempts];
    /* 全量 ip_change：tpmgr_shutdown_all 淘汰被服务器无视的半开连接 +
     * 新连接 re-REGISTER。间隔 > REGISTER tsx 超时（32s），保证上一轮
     * 终结后才发下一轮（上游对重叠的 ip_change 只告警不阻止，重叠会
     * 错乱状态机）；触发的进度回调不在恢复周期内，handleIpChangeProgress
     * 仅日志 */
    ys_handle_ip_change();
    [self scheduleRegWatchTick];
}

/* 注册成功（status==200，handleRegisterState 调 success=YES）或引擎关闭
 * （engineShutdown 调 NO）时停止监督 */
- (void)stopRegWatch:(BOOL)success
{
    if (_regWatchTimer != nil) {
        [_regWatchTimer invalidate];
        _regWatchTimer = nil;
    }
    if (success && _regWatchActive) {
        [self webrtcLog:@"[net-recovery] reg watch: registered OK (after %d attempt(s))",
            _regWatchAttempts];
    }
    _regWatchActive = NO;
    _regWatchAttempts = 0;
}

#pragma mark - 会话终结 / PeerConnection 释放（安卓 :1690-1741）

/* 强制以指定终态结束会话（本地失败路径） */
- (void)terminateSession:(SipCallSession *)session view:(NSString *)view
{
    if (session.isTerminal) {
        return;
    }
    session.callStateView = view;
    [self onSessionTerminated:session];
    [self notifySessionChanged:session];
}

/* 终态收口（幂等）：释放 WebRTC 资源、停提示音、登记延迟清除 */
- (void)onSessionTerminated:(SipCallSession *)session
{
    if (session.terminatedAt != 0) {
        return;
    }
    long long now = SipCurrentTimeMillis();
    session.terminatedAt = now;
    session.finalizeRemoveAt = now + SipCallSessionRegistry.terminalLingerMs;
    /* CallKit：终态上报（reason 映射见 coordinator endedReasonForSession）；
     * 挂起的接听动作一并收掉 */
    if (_callKitCoordinator != nil && session.callKitUuid != nil) {
        [_callKitCoordinator sessionEnded:session];
    }
    [self cancelAudioForceWatchdog];
    [self closePeerConnection:session suffix:@""];
    if (session.isIncoming) {
        [SipRingtoneHelper stopRingtone];
    } else {
        [SipRingtoneHelper stopBackTone];
    }
    /* 终态短暂可见后从 callList 移除。移除后必须再推一次快照：
     * JS 关闭通话页依赖收到空 callList（>0→0 触发面板关闭），
     * 只 purge 不通知 = JS 永远停在含终态的最后一个列表 → 界面卡死 */
    long long lingerMs = SipCallSessionRegistry.terminalLingerMs + 100;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(lingerMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        /* 强引用 session：即使已被 purge 也照常触发（消费方拉全量
         * 快照，session 参数仅触发用） */
        [self.registry purgeExpiredNow];
        [self notifySessionChanged:session];
    });
}

- (void)closePeerConnection:(SipCallSession *)session suffix:(NSString *)suffix
{
    [self cancelGatherWatchdog:session];
    /* gather 计时/零候选预算计时随会话释放清除（终态滞留窗口后防泄漏） */
    [self.gatherStartTimes removeObjectForKey:@(session.sessionId)];
    [self.zeroCandidateSinceMs removeObjectForKey:@(session.sessionId)];
    if (session.peerConnection) {
        [session.peerConnection close];
        session.peerConnection = nil;
    }
    /* ObjC WebRTC track/source 无显式 dispose（ARC 释放，对齐安卓 dispose 语义） */
    session.audioTrack = nil;
    session.audioSource = nil;
    [self webrtcLog:@"PeerConnection closed (call %ld)%@",
        (long)session.callId, suffix];
}

- (void)notifySessionChanged:(SipCallSession *)session
{
    if (_callback) {
        [_callback onCallSessionChanged:[session toDictionary]];
    }
}

#pragma mark - RTCPeerConnectionDelegate（回调线程 → 统一 dispatch 主线程，
/* 对齐安卓 SessionPcObserver；会话经 pc 指针回查 registry） */

- (SipCallSession *)sessionForPeerConnection:(RTCPeerConnection *)pc
{
    for (SipCallSession *session in [self.registry snapshot]) {
        if (session.peerConnection == pc) {
            return session;
        }
    }
    return nil;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeSignalingState:(RTCSignalingState)stateChanged
{
    /* 信令态变化由 offer/answer 链自身驱动，无需处理 */
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
           didAddStream:(RTCMediaStream *)stream
{
    /* Unified Plan 下走 didAddReceiver（可选），此处无操作 */
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
        didRemoveStream:(RTCMediaStream *)stream
{
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection
{
    /* 重协商一律由业务侧（hold/reinvite）显式发起 */
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceConnectionState:(RTCIceConnectionState)newState
{
    dispatch_async(dispatch_get_main_queue(), ^{
        SipCallSession *session = [self sessionForPeerConnection:peerConnection];
        if (session != nil) {
            [self webrtcLog:@"[ice-conn] call %ld %@",
                (long)session.callId, [self.class iceConnName:newState]];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceGatheringState:(RTCIceGatheringState)newState
{
    dispatch_async(dispatch_get_main_queue(), ^{
        SipCallSession *session = [self sessionForPeerConnection:peerConnection];
        if (session == nil) {
            return;
        }
        [self webrtcLog:@"[ice-gather] call %ld gather=%ld",
            (long)session.callId, (long)newState];
        if (newState == RTCIceGatheringStateComplete) {
            [self cancelGatherWatchdog:session];
            /* gather 完成耗时（呼出/re-INVITE 链共用此一处完成点；AC-6
             * 呼出延时量化——INVITE/200/re-INVITE 提交前最后一个 gather 点，
             * host-only 候选下该点显著提前） */
            NSNumber *startMs = self.gatherStartTimes[@(session.sessionId)];
            if (startMs != nil) {
                [self.gatherStartTimes removeObjectForKey:@(session.sessionId)];
                [self webrtcLog:@"gather complete (%lldms, call %ld)",
                    SipCurrentTimeMillis() - startMs.longLongValue,
                    (long)session.callId];
            }
            if (session.answerPending) {
                [self sendAnswerWithLocalSdp:session];
            } else if (session.reinvitePending) {
                [self sendReinviteWithLocalSdp:session];
            } else {
                [self sendInviteWithLocalSdp:session];
            }
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didGenerateIceCandidate:(RTCIceCandidate *)candidate
{
    /* 每来一个候选重臂 150ms 落盘窗（安静期去抖，对齐安卓 onIceCandidate
     * → CANDIDATE_FLUSH_MS）：最后一个候选 +150ms 即发待发 SDP，不等
     * COMPLETE（iOS 该状态永不到达） */
    dispatch_async(dispatch_get_main_queue(), ^{
        SipCallSession *session = [self sessionForPeerConnection:peerConnection];
        if (session != nil) {
            [self armGatherWatchdog:session afterSec:kSipCandidateFlushSec];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates
{
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
      didOpenDataChannel:(RTCDataChannel *)dataChannel
{
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeConnectionState:(RTCPeerConnectionState)newState
{
    dispatch_async(dispatch_get_main_queue(), ^{
        SipCallSession *session = [self sessionForPeerConnection:peerConnection];
        if (session != nil) {
            [self webrtcLog:@"[pc-state] call %ld %@",
                (long)session.callId, [self.class pcStateName:newState]];
        }
    });
}

#pragma mark - 通话质量解析（安卓 parseQuality:733-785 + CallDelegate
/* getCallQualityJson / qualityBars / networkTypeName） */

- (NSString *)qualityJsonWithReport:(RTCStatisticsReport *)report
{
    BOOL valid = NO;
    double jitterMs = 0.0;
    double lossPct = -1.0;
    double rttMs = -1.0;
    NSString *outboundCodecId = nil;

    for (RTCStatistics *stats in report.statistics.allValues) {
        if ([stats.type isEqualToString:@"inbound-rtp"]) {
            valid = YES;
            NSObject *jitter = stats.values[@"jitter"];
            if ([jitter isKindOfClass:[NSNumber class]]) {
                /* jitter 单位秒（W3C），转 ms */
                jitterMs = ((NSNumber *)jitter).doubleValue * 1000.0;
            }
            NSObject *lost = stats.values[@"packetsLost"];
            NSObject *received = stats.values[@"packetsReceived"];
            if ([lost isKindOfClass:[NSNumber class]]
                && [received isKindOfClass:[NSNumber class]]) {
                long long l = ((NSNumber *)lost).longLongValue;
                long long r = ((NSNumber *)received).longLongValue;
                if (r + l > 0) {
                    lossPct = (double)l * 100.0 / (double)(l + r);
                }
            }
        } else if ([stats.type isEqualToString:@"outbound-rtp"]) {
            NSObject *rtt = stats.values[@"roundTripTime"];
            if ([rtt isKindOfClass:[NSNumber class]]) {
                rttMs = ((NSNumber *)rtt).doubleValue * 1000.0;
            }
            NSObject *codecId = stats.values[@"codecId"];
            if ([codecId isKindOfClass:[NSString class]]) {
                outboundCodecId = (NSString *)codecId;
            }
        }
    }

    /* codec：按 outbound codecId 关联（老字段集缺 mimeType 时回退 OPUS） */
    NSString *codec = @"";
    if (outboundCodecId.length > 0) {
        RTCStatistics *codecStats = report.statistics[outboundCodecId];
        NSObject *mimeType = codecStats.values[@"mimeType"];
        if ([mimeType isKindOfClass:[NSString class]]
            && ((NSString *)mimeType).length > 0) {
            NSRange slash = [(NSString *)mimeType rangeOfString:@"/"
                                                        options:NSBackwardsSearch];
            codec = (slash.location == NSNotFound)
                ? [(NSString *)mimeType uppercaseString]
                : [[(NSString *)mimeType substringFromIndex:slash.location + 1]
                    uppercaseString];
        }
    }
    if (codec.length == 0) {
        codec = @"OPUS";
    }

    /* bars 评分（1-5，对齐安卓 qualityBars）：丢包优先，其次抖动与
     * RTT；无样本（valid=false，通话刚建立统计未生成）回中性 3 格 */
    int bars;
    if (!valid) {
        bars = 3;
    } else if (lossPct >= 15.0) {
        bars = 1;
    } else if (lossPct >= 8.0) {
        bars = 2;
    } else if (lossPct >= 3.0 || jitterMs > 80.0 || (rttMs >= 0 && rttMs > 500.0)) {
        bars = 3;
    } else if (lossPct >= 1.0 || jitterMs > 40.0 || (rttMs >= 0 && rttMs > 250.0)) {
        bars = 4;
    } else {
        bars = 5;
    }

    NSDictionary *quality = @{
        @"bars": @(bars),
        @"network": self.currentNetworkName ?: @"",
        @"codec": codec,
        @"jitterMs": @(jitterMs > 0.0 ? (int)(jitterMs + 0.5) : 0),
        @"packetLossPct": @(lossPct >= 0.0 ? (round(lossPct * 10.0) / 10.0) : 0.0),
        @"roundTripMs": @(rttMs >= 0.0 ? (int)(rttMs + 0.5) : 0),
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:quality
                                                    options:0
                                                      error:&error];
    if (data == nil) {
        [self webrtcLog:@"quality JSON encode FAILED: %@",
            error.localizedDescription];
        return @"";
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSString *)currentNetworkName
{
    /* NWPathMonitor 在 ensureWebRtc 启动，此处仅读缓存（主线程） */
    return _networkName ?: @"";
}

#pragma mark - 日志 / 线程工具

- (void)logLine:(NSString *)line
{
    [SipCoreLogger log:@"%@", line];
    id<SipEngineCallback> callback = _callback;
    if (!callback) {
        return;
    }
    /* 回调契约：主线程触发（logLine 可能从后台队列被调，统一转投） */
    dispatch_async(dispatch_get_main_queue(), ^{
        [callback onLog:(int)SipLogLevelInfo message:line];
    });
}

- (void)engineLog:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self logLine:[NSString stringWithFormat:@"%@ %@", SipLogPrefixEngine, body]];
}

- (void)ysLog:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self logLine:[NSString stringWithFormat:@"%@ %@", SipLogPrefixYs, body]];
}

- (void)webrtcLog:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self logLine:[NSString stringWithFormat:@"%@ %@", SipLogPrefixWebrtc, body]];
}

- (void)runOnMain:(void (^)(void))block
{
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

+ (NSString *)callStateName:(int)state
{
    switch (state) {
        case SipPjsuaStateNull:
            return @"NULL";
        case SipPjsuaStateCalling:
            return @"CALLING";
        case SipPjsuaStateIncoming:
            return @"INCOMING";
        case SipPjsuaStateEarly:
            return @"EARLY";
        case SipPjsuaStateConnecting:
            return @"CONNECTING";
        case SipPjsuaStateConfirmed:
            return @"CONFIRMED";
        case SipPjsuaStateDisconnected:
            return @"DISCONNECTED";
        default:
            return @"?";
    }
}

+ (NSString *)iceConnName:(RTCIceConnectionState)state
{
    switch (state) {
        case RTCIceConnectionStateNew:
            return @"new";
        case RTCIceConnectionStateChecking:
            return @"checking";
        case RTCIceConnectionStateConnected:
            return @"connected";
        case RTCIceConnectionStateCompleted:
            return @"completed (ICE+DTLS)";
        case RTCIceConnectionStateFailed:
            return @"FAILED";
        case RTCIceConnectionStateDisconnected:
            return @"disconnected";
        case RTCIceConnectionStateClosed:
            return @"closed";
        default:
            return @"?";
    }
}

+ (NSString *)pcStateName:(RTCPeerConnectionState)state
{
    switch (state) {
        case RTCPeerConnectionStateNew:
            return @"new";
        case RTCPeerConnectionStateConnecting:
            return @"connecting";
        case RTCPeerConnectionStateConnected:
            return @"CONNECTED";
        case RTCPeerConnectionStateDisconnected:
            return @"disconnected";
        case RTCPeerConnectionStateFailed:
            return @"FAILED";
        case RTCPeerConnectionStateClosed:
            return @"closed";
        default:
            return @"?";
    }
}

@end
