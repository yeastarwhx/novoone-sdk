package com.yeastar.sipcore;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.SessionDescription;
import org.webrtc.SdpObserver;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.util.Collections;
import java.util.List;

/**
 * 呼叫引擎 + PeerConnection 生命周期（多通话会话化改造版）。
 *
 * 移植自 novoone-sip-demo SipWebrtcEngine（单通话），结构性差异（arch
 * -design §3.3）：
 *   1. 单通话引擎字段（pc/audioTrack/awaitingAnswer/onHold...）全部下沉
 *      到 {@link CallSession}，经 {@link CallSessionRegistry} 管理多通话
 *      （上限 2）；
 *   2. 来电手动接听：onIncomingSdp 缓存 offer 与 INVITE 头，等
 *      callAnswer / callReject（demo 为自动 answer）；
 *   3. 呼出 requestId：make_call 前经 ys_set_outgoing_invite_headers 注入
 *      X-Request-ID 头（一次性消费）；
 *   4. 状态视图：pjsua state/last_status → CallSession.callStateView
 *      （detail-design §2.1 映射），经 EngineCallback 上抛。
 *
 * 线程模型（红线）：全部状态收敛主线程 Handler——ys_* 回调来自 pjsua
 * worker 线程（postXxx 转主线程），WebRTC SdpObserver / PeerConnection
 * Observer 回调来自内部线程（SdpObserverBase / SessionPcObserver 统一
 * post 主线程）。native 调用由 Java 线程串行先行（jclass 缓存前提，
 * 见 JniBridge 注释），不得在 ys 回调线程内直接调 native。
 *
 * 调用方约定：公开呼叫/账号操作应在主线程调用（delegate 层经
 * executeOnMain）；非主线程调用时引擎自动 post 主线程执行（布尔/句柄
 * 返回值退化为"已受理"）。
 */
public class SipWebrtcEngine {

    private static final String TAG = "SipWebrtcEngine";

    /* ys_pjsip_inv_state（对齐 ys_pjsua_app.h，0..6） */
    public static final int CALL_STATE_NULL = 0;
    public static final int CALL_STATE_CALLING = 1;
    public static final int CALL_STATE_INCOMING = 2;
    public static final int CALL_STATE_EARLY = 3;
    public static final int CALL_STATE_CONNECTING = 4;
    public static final int CALL_STATE_CONFIRMED = 5;
    public static final int CALL_STATE_DISCONNECTED = 6;

    /** 自研 SDK 版本号（独立定义的版本序列，与 RN 工程 version /
     *  安卓 versionName 同值，非 app 版本 26.x 推导；服务器按 UA 版本
     *  首位 >= 100 识别自研栈）。 */
    private static final String SDK_VERSION = "126.9.1";

    /** 统一 User-Agent：REGISTER/INVITE 等所有出站消息携带同一 UA。 */
    private static String buildUserAgent(Context ctx) {
        String androidId = android.provider.Settings.Secure.getString(
                ctx.getContentResolver(),
                android.provider.Settings.Secure.ANDROID_ID);
        if (androidId == null || androidId.isEmpty()) {
            androidId = "unknown";
        }
        /* 前缀 Mobile：旧栈核心标记（推送配对等既有链路依赖），不得改动
         * 。
         * 自研 SDK 识别约定：服务器按「UA 版本首位 >= 100」
         * 识别自研 WebRTC 栈并对其强制 DTLS（呼入 INVITE 下发带 ICE/DTLS
         * 的 offer）；旧栈版本首位为年份两位数（26/27…99），永不 >= 100，
         * 新旧判定无歧义 */
        return "Mobile/" + SDK_VERSION + "-Android-" + androidId;
    }

    /* ICE gathering 看门狗：首候选（host）到达后 150ms 落盘即发，
     * 不等 COMPLETE；800ms 为候选回调异常的兜底窗 */
    private static final long GATHER_WATCHDOG_MS = 800;

    /* 候选到达后的 localDescription 落盘窗（候选回调先于描述可读的
     * 保守间隔；过后读取即含全部候选） */
    private static final long CANDIDATE_FLUSH_MS = 150;

    /* 呼入初始应答零候选保护预算：answer 零 a=candidate 时
     * 不发送——延长等待收集（看门狗周期性重查）；预算耗尽仍零候选则
     * 486 拒接。依据：①明文 TCP 下中间设备（SIP ALG/IPS）会静默
     * 丢弃零候选的 200；②零候选 answer 媒体
     * 本就无法建立（服务器非 trickle）。仅作用于呼入初始应答（re-INVITE
     * 应答复用已收集候选，不触发）。 */
    private static final long ZERO_CANDIDATE_BUDGET_MS = 6000;

    private static volatile SipWebrtcEngine sInstance;

    public static SipWebrtcEngine getInstance() {
        if (sInstance == null) {
            synchronized (SipWebrtcEngine.class) {
                if (sInstance == null) {
                    sInstance = new SipWebrtcEngine();
                }
            }
        }
        return sInstance;
    }

    private final Handler main = new Handler(Looper.getMainLooper());

    /* 会话注册表（引擎级唯一，多通话核心容器） */
    private final CallSessionRegistry registry = new CallSessionRegistry();

    /* WebRTC 引擎级共享件 */
    /* 回声消除开关（默认开；变更在引擎重建/下次启动的 ADM 创建生效——
     * JavaAudioDeviceModule 的 AEC 策略创建时定死） */
    private volatile boolean echoCancelEnabled = true;
    /* 麦克风（发送）增益：m69 AudioSource 无 setVolume，挂 AudioTrack
     * .setVolume（标度 0.0~10.0，1.0 不增益）；App 契约 -10~10 线性
     * 映射由 delegate 完成 */
    private volatile double micGain = 1.0;
    private Context appContext;
    private PeerConnectionFactory factory;
    private JavaAudioDeviceModule adm;      /* engine 持引用，shutdown 时释放 */
    /* WebRTC 初始化失败（如 aar 绑定类缺失）时降级为纯信令模式：
     * pjsua 注册/呼叫控制仍可用，媒体不可用并逐次记日志 */
    private boolean webrtcFailed;

    /* pjsua 生命周期 / 账号 */
    private boolean started;
    private int accId = -1;

    /* ------------------------ 网络切换恢复 ------------------------ */
    /** pjsua_ip_change_op 枚举值（pjsua.h）：Java 侧无法引用 C 头，常量
     *  手工对齐（改库枚举须同步此处） */
    private static final int IP_CHANGE_STEP_SHUTDOWN_TP = 1;
    private static final int IP_CHANGE_STEP_COMPLETED = 7;
    /** ip_change DONE 看门狗：服务器无响应等异常下按已完成部分收尾
     *  （媒体恢复已在 SHUTDOWN_TP 步触发，不依赖此看门狗） */
    private static final long IP_CHANGE_TIMEOUT_MS = 5000;

    private NetworkMonitor networkMonitor;
    /* 编排单飞：一轮恢复进行中时新换网事件只标记重跑（防抖后仍可能
     * 残余连发，如双网竞态） */
    private boolean netRecoveryRunning = false;
    private boolean netRecoveryPendingRerun = false;
    private Runnable ipChangeWatchdog = null;
    private long netRecoveryStartMs = 0;

    /* 注册重试：服务器对旧连接占位期间的新连接 REGISTER 可能不响应，
     * 周期再走一轮 ip_change（强制换连接）直至注册成功 */
    private static final long REG_WATCH_INTERVAL_MS = 35000;
    private static final int REG_WATCH_MAX_ATTEMPTS = 15;
    private int lastRegStatus = 0;
    private boolean regWatchActive = false;
    private int regWatchAttempts = 0;
    private Runnable regWatchRunnable = null;

    /* transport：0=UDP 1=TCP 2=TLS（对齐 ys_set_sip_transport；TLS 须库
     * 以 SSL 宏交付编译） */
    public static final int TRANSPORT_UDP = 0;
    public static final int TRANSPORT_TCP = 1;
    public static final int TRANSPORT_TLS = 2;
    private int transport = TRANSPORT_UDP;

    private EngineCallback callback;

    /* ICE STUN 服务器配置（保留接口，当前不用于候选收集——
     * 候选极简化策略下仅收集 host 候选） */
    private volatile java.util.List<PeerConnection.IceServer> stunServers =
            Collections.singletonList(PeerConnection.IceServer
                    .builder("stun:stun.cloudflare.com:3478")
                    .createIceServer());

    private SipWebrtcEngine() {
    }

    /* ------------------------------------------------------------------ */
    /* 对外查询                                                            */
    /* ------------------------------------------------------------------ */

    public boolean isStarted() {
        return started;
    }

    /** WebRTC 是否可用（aar 完整时 true；false = 纯信令降级，不可呼出/接听） */
    public boolean isWebRtcReady() {
        return factory != null && !webrtcFailed;
    }

    public int getAccId() {
        return accId;
    }

    /** 当前引擎传输（0=UDP 1=TCP 2=TLS；未启动为初始 UDP） */
    public int getTransport() {
        return transport;
    }

    /**
     * 外部模块诊断日志入口（App 层 Logger 在 release 构建不进 logcat，
     * 关键链路如推送上报可经此输出，tag 统一 SipWebrtcEngine）。
     */
    public void logExternal(String msg) {
        log(msg);
    }

    /**
     * 回声消除开关（默认开）。变更在下次 ADM 创建（引擎重建/重启）生效，
     * 存活通话不受影响——AEC 策略在 JavaAudioDeviceModule 创建时定死。
     */
    public void setEchoCancelEnabled(boolean enabled) {
        echoCancelEnabled = enabled;
        /* 软件回声消除随引擎常开（恒定），开关暂无独立生效点——见
         * ADM 构建处注释 */
        log("[webrtc] echoCancel setting recorded: " + enabled
                + " (software AEC always on)");
    }

    /**
     * 麦克风（发送）增益：AudioTrack.setVolume 标度 0.0~10.0，1.0 不
     * 增益。对活跃通话立即生效（逐会话），并影响之后新建的会话。
     */
    public void setMicGain(double gain) {
        micGain = Math.max(0.0, Math.min(10.0, gain));
        log("[webrtc] micGain=" + micGain);
        for (CallSession s : registry.snapshot()) {
            try {
                if (s.audioTrack != null && !s.isTerminal()) {
                    s.audioTrack.setVolume(micGain);
                }
            } catch (Throwable ignored) {
            }
        }
    }

    /**
     * 设置 ICE STUN 服务器（服务器下发，格式 "host[:port]" 逗号分隔；
     * 空串/空数组保持现状）。仅影响之后新建的 PeerConnection。
     */
    public void setStunServers(String commaSeparated) {
        if (commaSeparated == null || commaSeparated.trim().isEmpty()) {
            return;
        }
        java.util.List<PeerConnection.IceServer> list =
                new java.util.ArrayList<>();
        for (String raw : commaSeparated.split(",")) {
            String addr = raw.trim();
            if (addr.isEmpty()) {
                continue;
            }
            if (!addr.startsWith("stun:")) {
                addr = "stun:" + addr;
            }
            list.add(PeerConnection.IceServer.builder(addr).createIceServer());
        }
        if (!list.isEmpty()) {
            stunServers = list;
            log("[engine] STUN servers set: " + commaSeparated);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 生命周期                                                            */
    /* ------------------------------------------------------------------ */

    /**
     * 初始化 pjsua + WebRTC factory（账号注册另走 accountRegister）。
     * 传输类型须在此定死（ys_set_sip_transport 须在 ys_init_pjsua 前调用），
     * 运行期换 transport 需 engineShutdown 后重启引擎。
     *
     * @return true 初始化成功；false 失败（.so 缺失等，引擎标记不可用）
     */
    public synchronized boolean engineStart(Context context, EngineCallback cb,
                                            int transport) {
        if (started) {
            log("[engine] already started");
            return true;
        }
        if (transport < 0 || transport > 2) {
            log("[engine] invalid transport " + transport);
            return false;
        }
        this.callback = cb;
        this.transport = transport;

        try {
            appContext = context.getApplicationContext();
            ensureWebRtc(appContext);

            if (JniBridge.nativeSetTransport(transport) != 0) {
                log("[engine] ys_set_sip_transport failed");
                return false;
            }

            /* 统一 User-Agent：REGISTER/INVITE 等所有出站消息携带同一 UA。
             * 格式对齐旧栈 "Mobile/{appVersion}-Android-{ANDROID_ID}"（服务端
             * 可能结合 UA 识别客户端类型） */
            JniBridge.nativeSetUserAgent(buildUserAgent(appContext));

            /* 本地 SIP 端口 5060（仅 UDP 绑定语义；TCP 走随机端口，
             * 见 ys_init_pjsua 的 transport 分支） */
            if (JniBridge.nativeInitPjsua(5060) != 0) {
                log("[engine] ys_init_pjsua failed");
                return false;
            }

            started = true;
            log("[engine] pjsua started (ys layer, "
                    + (transport == TRANSPORT_TLS ? "TLS"
                        : (transport == TRANSPORT_TCP ? "TCP" : "UDP")) + ")");

            /* 网络变化检测：换网事件（防抖后）驱动信令+媒体恢复链。
             * 启动即以当前网络为基线，不触发首轮恢复 */
            if (networkMonitor == null) {
                networkMonitor = new NetworkMonitor(appContext,
                        new NetworkMonitor.Listener() {
                            @Override
                            public void onNetworkChanged(String reason) {
                                handleNetworkChanged(reason);
                            }
                        });
            }
            networkMonitor.start();
            return true;
        } catch (Throwable t) {
            /* .so 缺失 / aar 异常：引擎 broken，后续所有操作失败
             * （detail-design §1.1，登录流程不阻断） */
            log("[engine] init FAILED: " + t + " -> engine broken");
            Log.e(TAG, "engine init failed", t);
            return false;
        }
    }

    /** pjsua 销毁耗时（秒级），调用方应放后台线程（对齐 demo）。此后引擎不可再用。 */
    public void engineShutdown() {
        /* 线程模型红线：会话/Registry/RingtoneHelper 仅主线程可碰——
         * 调用方（transport 变更的 engineScope IO 线程）一律 post 主线程
         * 执行实际销毁；调用方不等待（销毁秒级，重建由调用方另行 post） */
        post(new Runnable() {
            @Override
            public void run() {
                engineShutdownOnMain();
            }
        });
    }

    private synchronized void engineShutdownOnMain() {
        if (!started) {
            return;
        }
        started = false;
        if (networkMonitor != null) {
            networkMonitor.stop();
        }
        netRecoveryRunning = false;
        netRecoveryPendingRerun = false;
        if (ipChangeWatchdog != null) {
            main.removeCallbacks(ipChangeWatchdog);
            ipChangeWatchdog = null;
        }
        stopRegWatch(false);
        JniBridge.nativeHangupAll();
        for (CallSession s : registry.snapshot()) {
            cancelGatherWatchdog(s);
            closePeerConnection(s, " (shutdown)");
        }
        registry.clear();
        /* 清延迟任务（终态 purge 的 postDelayed 不再触发，避免对已清
         * 会话 notifySessionChanged）与回调引用（释放 RN delegate） */
        main.removeCallbacksAndMessages(null);
        callback = null;
        RingtoneHelper.stopAll();
        JniBridge.nativeDestroy();
        if (factory != null) {
            factory.dispose();
            factory = null;
        }
        if (adm != null) {
            adm.release();
            adm = null;
        }
        accId = -1;
    }

    /* ------------------------------------------------------------------ */
    /* 账号                                                                */
    /* ------------------------------------------------------------------ */

    /**
     * 注册账号（重复调用先注销旧账号再注册 —— 凭证变更走此路径）。
     *
     * @return accId (>=0)，失败 -1；注册结果经 onRegisterState 回调上抛
     */
    public int accountRegister(final String server, final String user,
                               final String pass, final String proxy) {
        return accountRegister(server, user, pass, proxy, null, null, 0);
    }

    /**
     * 注册账号（完整参数）。authUser 独立认证用户名（null = 同 user）、
     * displayName From 显示名（null = 无）、expires 注册时效秒（<=0 库默认）。
     */
    public int accountRegister(final String server, final String user,
                               final String pass, final String proxy,
                               final String authUser, final String displayName,
                               final int expires) {
        if (!started) {
            log("[engine] start first");
            return -1;
        }
        Integer result = runOnMain(new java.util.concurrent.Callable<Integer>() {
            @Override
            public Integer call() {
                if (accId >= 0) {
                    JniBridge.nativeUnregisterAccount(accId);
                    accId = -1;
                }
                accId = JniBridge.nativeRegisterAccount(server, user, pass,
                        proxy != null ? proxy : "",
                        authUser, displayName, expires);
                if (accId < 0) {
                    /* 失败原因自解释：JNI 层对 server/user/pass 为 NULL 静默
                     * 返回 -1（不进 pjsip、无库层日志），此处必须打出参数状态 */
                    log("[engine] ys_register_account failed (server="
                            + (server == null ? "NULL" : server)
                            + " user=" + (user == null ? "NULL" : user)
                            + " pass=" + (pass == null ? "NULL" : "len=" + pass.length())
                            + ")");
                } else {
                    log("[engine] registering " + user + " via " + server
                            + (proxy != null && !proxy.isEmpty()
                                    ? " (proxy " + proxy + ")" : "")
                            + (authUser != null && !authUser.isEmpty()
                                    ? " (auth " + authUser + ")" : "") + " ...");
                }
                return accId;
            }
        });
        return result != null ? result : -1;
    }

    /** 注销并删除账号（登出）。@return true 成功 */
    public boolean accountUnregister() {
        if (!started) {
            return false;
        }
        Boolean result = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                if (accId < 0) {
                    return false;
                }
                int rc = JniBridge.nativeUnregisterAccount(accId);
                if (rc == 0) {
                    accId = -1;
                    log("[engine] account unregistered");
                    return true;
                }
                log("[ys] ys_unregister_account failed");
                return false;
            }
        });
        return result != null && result;
    }

    /**
     * 刷新注册（重发 REGISTER，不删账号、不影响进行中的通话）。
     * 推送唤醒场景账号在册时使用——删号重建会强制拆除正在振铃的
     * 通话（deleting account while call is active）。
     * @return true 成功
     */
    public boolean accountReregister() {
        if (!started) {
            return false;
        }
        Boolean result = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                if (accId < 0) {
                    return false;
                }
                int rc = JniBridge.nativeReregisterAccount(accId);
                if (rc == 0) {
                    log("[engine] account re-REGISTER");
                    return true;
                }
                log("[ys] ys_reregister_account failed");
                return false;
            }
        });
        return result != null && result;
    }

    /* ------------------------------------------------------------------ */
    /* 呼叫操作（delegate 层在主线程调用）                                 */
    /* ------------------------------------------------------------------ */

    /**
     * 呼出：requestId 注入 INVITE X-Request-ID 头（一次性消费）后走
     * offer → gather(2s 看门狗) → make_call 链。
     *
     * @return 会话句柄 sessionId（>=1；pjsua callId 在 INVITE 提交后经
     *         onCallSessionChanged 可读），-1 = 立即失败（未启动/超上限/
     *         WebRTC 不可用）
     */
    public long callMake(final String number, final String requestId) {
        if (!started) {
            log("[engine] start first");
            return -1;
        }
        if (!isWebRtcReady()) {
            log("[engine] WebRTC unavailable - cannot dial");
            return -1;
        }
        final CallSession s = registry.create(CallSession.DIRECTION_OUT);
        if (s == null) {
            log("[engine] call rejected: MAX_CONCURRENT ("
                    + CallSessionRegistry.MAX_SESSIONS + ")");
            return -1;
        }
        s.remoteNumber = number;
        s.requestId = requestId;
        /* groupId 创建即赋且保持稳定（= sessionId）：ICE gather 窗口期
         * （最长 2s，INVITE 未提交）JS 的挂断等操作已可经 entry 定位；
         * INVITE 提交获得 pjsua callId 后也不得改写（JS 持有的旧
         * entry.groupId 会失效） */
        s.groupId = String.valueOf(s.sessionId);
        log("[engine] call out -> " + number
                + (requestId != null ? " (X-Request-ID " + requestId + ")" : ""));
        runOnMain(new Runnable() {
            @Override
            public void run() {
                startOutgoingCall(s);
            }
        });
        return s.sessionId;
    }

    /** 呼出链主体（主线程）：头注入 → PC 建立 → offer → gather → INVITE */
    private void startOutgoingCall(CallSession s) {
        if (s.isTerminal()) {
            return;
        }
        if (s.requestId != null && !s.requestId.isEmpty()) {
            if (JniBridge.nativeSetOutgoingInviteHeaders(
                    "X-Request-ID: " + s.requestId) != 0) {
                log("[ys] ys_set_outgoing_invite_headers failed");
            }
        }
        setupPeerConnection(s);
        if (s.pc == null) {
            log("[engine] WebRTC unavailable - cannot dial");
            terminateSession(s, CallSession.STATE_ERROR);
            return;
        }
        s.pc.createOffer(new SdpObserverBase(s) {
            @Override
            protected void onCreated(SessionDescription sdp) {
                if (s.pc == null) {
                    return;
                }
                log("[webrtc] offer generated (" + sdp.description.length()
                        + " bytes)");
                s.pc.setLocalDescription(new SdpObserverBase(s) {
                    @Override
                    protected void onSetDone() {
                        log("[webrtc] SetLocalDescription: OK");
                    }

                    @Override
                    protected void onFailed(String error) {
                        log("[webrtc] SetLocalDescription: " + error);
                    }
                }, sdp);
            }

            @Override
            protected void onFailed(String error) {
                log("[webrtc] CreateOffer FAILED: " + error);
                terminateSession(s, CallSession.STATE_ERROR);
            }
        }, new MediaConstraints());

        log("[webrtc] PeerConnection created -> " + s.remoteNumber);
    }

    /**
     * 接听来电（SRD(offer) → createAnswer → SLD → gather(2s 看门狗) →
     * ys_answer_call_with_sdp 200）。
     *
     * @return false 立即失败（会话不存在/非来电/已处理/WebRTC 不可用）
     */
    public boolean callAnswer(final long callId) {
        Boolean result = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                return answerInternal((int) callId);
            }
        });
        return result != null && result;
    }

    private boolean answerInternal(int callId) {
        CallSession s = registry.findByCallId(callId);
        if (s == null || !s.isIncoming()) {
            log("[engine] answer: no incoming call " + callId);
            return false;
        }
        if (s.answerRequested || s.isTerminal()) {
            log("[engine] answer: call " + callId + " already handled");
            return false;
        }
        if (!CallSession.STATE_INCOMING_TRYING.equals(s.callStateView)
                && !CallSession.STATE_INCOMING_RINGING.equals(s.callStateView)) {
            log("[engine] answer: call " + callId + " not in ringing state ("
                    + s.callStateView + ")");
            return false;
        }
        if (!isWebRtcReady()) {
            log("[engine] WebRTC unavailable - cannot answer");
            return false;
        }
        if (s.offerSdp == null || s.offerSdp.isEmpty()) {
            log("[engine] answer: offer missing -> reject 486");
            /* 呼入 offer 损坏/缺失：ys_reject_call 固定发 486 Decline
             * （语义等价"拒接"，服务器侧都按被叫拒绝收口）。收口对齐
             * rejectInternal：置 rejectRequested + 停铃声 + 视图乐观终态
             * ——防迟到的 DISCONNECTED 被 computeViewState 映射为
             * IncomingMissed（"已接听却显示未接"非法序列），且铃声不得
             * 响到对端取消 */
            s.rejectRequested = true;
            RingtoneHelper.stopRingtone();
            if (JniBridge.nativeRejectCall(callId) != 0) {
                log("[ys] ys_reject_call failed");
                s.rejectRequested = false;
                return false;
            }
            s.callStateView = CallSession.STATE_INCOMING_REJECTED;
            onSessionTerminated(s);
            notifySessionChanged(s);
            return false;
        }

        s.answerRequested = true;
        RingtoneHelper.stopRingtone();
        log("[engine] answering incoming call " + callId);

        setupPeerConnection(s);
        if (s.pc == null) {
            s.answerRequested = false;
            log("[engine] WebRTC unavailable - cannot answer incoming call");
            return false;
        }
        answerRemoteOffer(s, s.offerSdp);
        notifySessionChanged(s);
        return true;
    }

    /**
     * 拒接来电（振铃期 486 Decline，经 ys_reject_call）。
     *
     * @return false 立即失败（非来电/已接听/已终结，UI 提示"已结束"）
     */
    public boolean callReject(final long callId) {
        Boolean result = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                return rejectInternal((int) callId);
            }
        });
        return result != null && result;
    }

    private boolean rejectInternal(int callId) {
        CallSession s = registry.findByCallId(callId);
        if (s == null || !s.isIncoming()) {
            log("[engine] reject: no incoming call " + callId);
            return false;
        }
        if (s.answerRequested || s.isTerminal()) {
            log("[engine] reject: call " + callId + " already handled ("
                    + s.callStateView + ")");
            return false;
        }
        s.rejectRequested = true;
        RingtoneHelper.stopRingtone();
        if (JniBridge.nativeRejectCall(callId) != 0) {
            log("[ys] ys_reject_call failed");
            s.rejectRequested = false;
            return false;
        }
        log("[ys] rejected 486 (call " + callId + ")");
        /* 视图乐观置终态（DISCONNECTED 事件到达后幂等） */
        s.callStateView = CallSession.STATE_INCOMING_REJECTED;
        onSessionTerminated(s);
        notifySessionChanged(s);
        return true;
    }

    /** 挂断（BYE / CANCEL）；呼出未提交 INVITE 的会话直接本地终结 */
    public void callHangup(final long callId) {
        runOnMain(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null) {
                    log("[engine] hangup: no call " + callId);
                    return;
                }
                if (s.isTerminal()) {
                    return;
                }
                boolean sent = false;
                if (s.callId >= 0) {
                    sent = JniBridge.nativeHangup(s.callId) == 0;
                }
                if (!sent) {
                    log("[ys] hangup " + s.callId + " failed (or not sent)");
                }
                s.callStateView = CallSession.STATE_TERMINATED;
                onSessionTerminated(s);
                notifySessionChanged(s);
            }
        });
    }

    /**
     * REGISTER 附加自定义头（粘性：随之后的每次注册发出直到清除）。
     * 推送唤醒双头场景由 App 层在 3s 后传 null 撤除（对齐旧栈时序）。
     */
    public void setRegisterHeaders(final String headers) {
        runOnMain(new Runnable() {
            @Override
            public void run() {
                JniBridge.nativeSetRegisterHeaders(headers);
                log("[engine] REGISTER headers "
                        + (headers == null || headers.isEmpty()
                                ? "cleared" : "set (sticky until clear)"));
            }
        });
    }

    /**
     * 通话质量统计快照（WebRTC getStats 解析结果，App 侧 1s 轮询契约）
     */
    public static class CallQualityData {
        public String codec = "";       /* 如 "OPUS"（outbound codec mimeType 短名） */
        public double jitterMs;         /* 入站抖动 */
        public double lossPct = -1;     /* 入站丢包率（-1 = 尚无样本） */
        public double rttMs = -1;       /* 往返时延（-1 = 未知） */
        public boolean valid;           /* 是否取到有效统计 */
    }

    /** 质量查询回调（主线程） */
    public interface QualityCallback {
        void onQuality(CallQualityData data);
    }

    /**
     * 拉取通话质量统计（异步；无该通话/无 PeerConnection 时回 valid=false）。
     * 解析：inbound-rtp 的 jitter/packetsLost/packetsReceived 与
     * outbound-rtp 的 roundTripTime、codecId→codec mimeType。
     */
    public void getCallQuality(final long callId, final QualityCallback cb) {
        post(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null || s.pc == null) {
                    CallQualityData d = new CallQualityData();
                    cb.onQuality(d);
                    return;
                }
                try {
                    s.pc.getStats(new org.webrtc.RTCStatsCollectorCallback() {
                        @Override
                        public void onStatsDelivered(final org.webrtc.RTCStatsReport report) {
                            post(new Runnable() {
                                @Override
                                public void run() {
                                    cb.onQuality(parseQuality(report));
                                }
                            });
                        }
                    });
                } catch (Throwable t) {
                    log("[webrtc] getStats failed: " + t);
                    cb.onQuality(new CallQualityData());
                }
            }
        });
    }

    /** RTCStatsReport → CallQualityData（W3C 标准 stats 字段） */
    private static CallQualityData parseQuality(org.webrtc.RTCStatsReport report) {
        CallQualityData d = new CallQualityData();
        if (report == null) {
            return d;
        }
        String outboundCodecId = null;
        for (org.webrtc.RTCStats st : report.getStatsMap().values()) {
            java.util.Map<String, Object> m = st.getMembers();
            String type = st.getType();
            if ("inbound-rtp".equals(type)) {
                d.valid = true;
                Object jitter = m.get("jitter");
                if (jitter instanceof Number) {
                    /* jitter 单位秒（W3C），转 ms */
                    d.jitterMs = ((Number) jitter).doubleValue() * 1000.0;
                }
                Object lost = m.get("packetsLost");
                Object recv = m.get("packetsReceived");
                if (lost instanceof Number && recv instanceof Number) {
                    long l = ((Number) lost).longValue();
                    long r = ((Number) recv).longValue();
                    if (r + l > 0) {
                        d.lossPct = l * 100.0 / (l + r);
                    }
                }
            } else if ("outbound-rtp".equals(type)) {
                Object rtt = m.get("roundTripTime");
                if (rtt instanceof Number) {
                    d.rttMs = ((Number) rtt).doubleValue() * 1000.0;
                }
                Object cid = m.get("codecId");
                if (cid instanceof String) {
                    outboundCodecId = (String) cid;
                }
            }
        }
        /* codec：按 outbound codecId 关联（老字段集缺 mimeType 时回退 OPUS） */
        if (outboundCodecId != null) {
            org.webrtc.RTCStats cs = report.getStatsMap().get(outboundCodecId);
            if (cs != null) {
                Object mt = cs.getMembers().get("mimeType");
                if (mt instanceof String) {
                    String v = (String) mt;
                    int slash = v.lastIndexOf('/');
                    d.codec = slash >= 0 ? v.substring(slash + 1).toUpperCase() : v.toUpperCase();
                }
            }
        }
        if (d.codec.isEmpty()) {
            d.codec = "OPUS";
        }
        return d;
    }

    /** 盲转（REFER）：把指定通话转给 number（纯号码/完整 URI）。 */
    public boolean callXfer(final long callId, final String number) {
        Boolean ok = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null || s.isTerminal()) {
                    log("[engine] xfer: no call " + callId);
                    return false;
                }
                boolean rc = JniBridge.nativeXferCall(s.callId, number) == 0;
                log("[engine] blind xfer " + number + " -> " + (rc ? "sent" : "failed"));
                return rc;
            }
        });
        return ok != null && ok;
    }

    /**
     * 咨询转（REFER + Replaces）：callId 的对端与 destCallId 的对端建立
     * 通话（两路均为本方活跃通话）。成功后本方两路由服务器接管。
     */
    public boolean callXferAttended(final long callId, final long destCallId) {
        Boolean ok = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                CallSession a = registry.findByCallId((int) callId);
                CallSession b = registry.findByCallId((int) destCallId);
                if (a == null || b == null || a.isTerminal() || b.isTerminal()) {
                    log("[engine] attended xfer: missing call " + callId
                            + "/" + destCallId);
                    return false;
                }
                boolean rc = JniBridge.nativeXferReplaces(a.callId, b.callId) == 0;
                log("[engine] attended xfer " + callId + " x " + destCallId
                        + " -> " + (rc ? "sent" : "failed"));
                return rc;
            }
        });
        return ok != null && ok;
    }

    /**
     * 通话中 DTMF：RTP telephone-event 通道（RFC 4733；须对端 offer/answer
     * 已协商 telephone-event payload，否则 dtmfSender 为空并记日志）。
     * dtmfOn 一次发送完整音（duration 200ms / gap 100ms）；dtmfOff 为
     * no-op（App 契约的按下/松开成对调用，RTP DTMF 无持续发音语义）。
     */
    public boolean callDtmf(final long callId, final char digit) {
        Boolean ok = runOnMain(new java.util.concurrent.Callable<Boolean>() {
            @Override
            public Boolean call() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null || s.isTerminal() || s.audioTrack == null) {
                    log("[engine] dtmf: no call " + callId);
                    return false;
                }
                try {
                    /* DTMF 发送器挂在 RtpSender 上（须 audio m 行协商了
                     * telephone-event payload，否则 dtmf()/canInsertDtmf
                     * 不可用） */
                    org.webrtc.DtmfSender sender = null;
                    if (s.pc != null) {
                        for (org.webrtc.RtpSender rs : s.pc.getSenders()) {
                            org.webrtc.DtmfSender d = rs.dtmf();
                            if (d != null) {
                                sender = d;
                                break;
                            }
                        }
                    }
                    if (sender == null || !sender.canInsertDtmf()) {
                        log("[webrtc] dtmf sender unavailable "
                                + "(telephone-event not negotiated)");
                        return false;
                    }
                    boolean rc = sender.insertDtmf(String.valueOf(digit), 200, 100);
                    log("[webrtc] dtmf " + digit + " -> " + (rc ? "sent" : "failed"));
                    return rc;
                } catch (Exception e) {
                    log("[webrtc] dtmf exception: " + e);
                    return false;
                }
            }
        });
        return ok != null && ok;
    }

    /** REFER 转接进度（pjsua worker 线程转主线程）。final 2xx = 转接
     * 成功（对端已与新目标建立通话），本方自动挂断；final 非 2xx 失败，
     * 保持通话状态由用户决定。 */
    void postTransferState(final int cid, final int status, final int isFinal) {
        post(new Runnable() {
            @Override
            public void run() {
                log("[ys] transfer call " + cid + " status=" + status
                        + (isFinal != 0 ? " (final)" : ""));
                CallSession s = registry.findByCallId(cid);
                if (s == null) {
                    return;
                }
                if (isFinal != 0) {
                    if (status >= 200 && status < 300) {
                        log("[engine] transfer OK -> hanging up local leg");
                        callHangup(s.callId);
                    } else {
                        log("[engine] transfer FAILED (" + status + "), call kept");
                        notifySessionChanged(s);
                    }
                }
            }
        });
    }

    /**
     * hold/resume：本地 track 静音（offer 方向自动变 sendonly/recvonly）→
     * createOffer → SLD → 等 ICE → re-INVITE（sendonly/sendrecv，demo 已
     * 验证机制按会话隔离）。对端 hold/resume 走 postReinviteSdp answer 链。
     */
    public void callHold(final long callId, final boolean held) {
        runOnMain(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null || s.pc == null) {
                    log("[engine] " + (held ? "hold" : "resume")
                            + ": no call " + callId);
                    return;
                }
                if (s.isTerminal()) {
                    return;
                }
                holdInternal(s, held);
            }
        });
    }

    private void holdInternal(CallSession s, boolean held) {
        if (held) {
            /* 本地 offer 在途时 renegotiate 的 CreateOffer 会被 WebRTC 拒绝
             * （have-local-offer），先等上一个 offer 被 answer */
            if (s.awaitingAnswer) {
                log("[engine] previous offer not answered yet - hold later");
                return;
            }
            if (s.holdFlag) {
                log("[engine] already on hold");
                return;
            }
            s.holdFlag = true;
            s.holdStartTime = System.currentTimeMillis();
            applyTrackEnabled(s);
            applyTransceiverDirection(s, true);
            log("[webrtc] holding call " + s.callId + " (sendonly offer)");
            renegotiate(s, "hold-resume");
        } else {
            if (s.awaitingAnswer) {
                log("[engine] previous offer not answered yet - resume later");
                return;
            }
            if (!s.holdFlag) {
                log("[engine] not on hold");
                return;
            }
            s.holdFlag = false;
            s.holdStartTime = 0;
            applyTrackEnabled(s);
            applyTransceiverDirection(s, false);
            log("[webrtc] resuming call " + s.callId + " (sendrecv offer)");
            renegotiate(s, "hold-resume");
        }
        notifySessionChanged(s);
    }

    /**
     * hold 方向语义（RFC 3264 §8.4 unilateral hold）：hold = 我方 offer
     * sendonly（只发不收——对端/服务器向对方播放保持音，我方不再接收
     * 对端媒体）；resume = sendrecv。
     *
     * track.setEnabled 只控制数据发送、不改变 SDP 方向：m 行方向由
     * RtpTransceiver.direction 决定，不显式设置时 createOffer 恒
     * sendrecv——hold 对对端完全不可见。
     */
    private void applyTransceiverDirection(CallSession s, boolean held) {
        if (s.pc == null) {
            return;
        }
        org.webrtc.RtpTransceiver.RtpTransceiverDirection dir = held
                ? org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_ONLY
                : org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV;
        try {
            for (org.webrtc.RtpTransceiver t : s.pc.getTransceivers()) {
                t.setDirection(dir);
            }
        } catch (Exception e) {
            log("[webrtc] setDirection failed: " + e.getMessage());
        }
    }

    /**
     * 静音/取消静音：本地 track.setEnabled（不发 re-INVITE，对齐 Acrobits
     * 语义）；与 hold 叠加时 track 使能 = !mute && !hold。
     */
    /**
     * 会话级静音置位（SdkBridge 全局静音镜像用）：callId 尚未分配的
     * 新会话（呼出 INVITE 未发/来电刚到）按 sessionId 定位。track 未建
     * 时仅置 muteFlag——createAudioTrack 后的 applyTrackEnabled 消费。
     */
    public void setSessionMute(final long sessionId, final boolean muted) {
        runOnMain(new Runnable() {
            @Override
            public void run() {
                for (CallSession s : registry.snapshot()) {
                    if (s.sessionId == sessionId && s.muteFlag != muted) {
                        s.muteFlag = muted;
                        applyTrackEnabled(s);
                        notifySessionChanged(s);
                        return;
                    }
                }
            }
        });
    }

    public void callMute(final long callId, final boolean muted) {
        runOnMain(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId((int) callId);
                if (s == null) {
                    return;
                }
                if (s.muteFlag == muted) {
                    return;
                }
                s.muteFlag = muted;
                applyTrackEnabled(s);
                log("[webrtc] call " + s.callId + " mute=" + muted);
                notifySessionChanged(s);
            }
        });
    }

    /** 来电头缓存查询（X-Request-ID / X-Nov-Caller-ID-Name） */
    public String callGetHeader(final long callId, final String name) {
        CallSession s = registry.findByCallId((int) callId);
        if (s == null || name == null) {
            return null;
        }
        String n = name.trim().toLowerCase();
        if ("x-request-id".equals(n)) {
            return s.requestId;
        }
        if ("x-nov-caller-id-name".equals(n)) {
            return s.callerIdName;
        }
        return null;
    }

    /** 全部会话快照（含终态滞留，getActiveCalls 契约：任意时刻可查） */
    public List<CallSession> snapshotCalls() {
        registry.purgeExpired(System.currentTimeMillis());
        return registry.snapshot();
    }

    /* ------------------------------------------------------------------ */
    /* 音频路由门面（AudioRouteHelper 转发）                               */
    /* ------------------------------------------------------------------ */

    public AudioRouteHelper.RouteInfo audioGetCurrent() {
        return AudioRouteHelper.getCurrent(appContext);
    }

    public List<AudioRouteHelper.RouteInfo> audioGetAvailable() {
        return AudioRouteHelper.getAvailable(appContext);
    }

    public boolean audioSetRoute(String type) {
        boolean ok = AudioRouteHelper.setRoute(appContext, type);
        if (ok) {
            /* 路由切换影响 ActiveCallItem.audioRoute/audioExternal 字段：
             * 推一次快照让 JS 通话页按钮高亮跟随（JS 靠全量事件更新，
             * 不轮询路由） */
            post(new Runnable() {
                @Override
                public void run() {
                    CallSession active = registry.snapshot().isEmpty()
                            ? null : registry.snapshot().get(0);
                    if (active != null && !active.isTerminal()) {
                        notifySessionChanged(active);
                    }
                }
            });
        }
        return ok;
    }

    /* ------------------------------------------------------------------ */
    /* ys_* 回调入口（JniBridge，pjsua worker 线程 -> 转主线程）            */
    /* ------------------------------------------------------------------ */

    void postRegisterState(final int accId, final int status, final String text) {
        post(new Runnable() {
            @Override
            public void run() {
                log("[ys] reg acc=" + accId + " status=" + status
                        + " (" + (text != null ? text : "") + ")");
                lastRegStatus = status;
                if (status == 200) {
                    stopRegWatch(true);
                    log("[engine] registered OK");
                }
                if (callback != null) {
                    callback.onRegisterState(status, text);
                }
            }
        });
    }

    void postCallState(final int cid, final int state, final int lastStatus) {
        post(new Runnable() {
            @Override
            public void run() {
                registry.purgeExpired(System.currentTimeMillis());
                CallSession s = registry.findByCallId(cid);
                if (s == null) {
                    /* 终态清除后迟到的重复事件，或引擎未跟踪的呼叫 */
                    log("[ys] call " + cid + " state=" + callStateName(state)
                            + " last_code=" + lastStatus + " (no session)");
                    return;
                }
                log("[ys] call " + cid + " state=" + callStateName(state)
                        + " last_code=" + lastStatus);

                s.pjsuaState = state;
                s.lastStatus = lastStatus;
                if (state == CALL_STATE_CONFIRMED) {
                    if (s.callStartTime == 0) {
                        s.callStartTime = System.currentTimeMillis();
                        /* 首通初始路由决策（有线 > 蓝牙 > 听筒，显式设置）：
                         * 仅在此会话为当前唯一活跃通话时执行，不打扰已有
                         * 通话中用户手动选择的路由（见 applyInitialRoute
                         * 注释：OEM 自动 SCO 与显示脱节的根治） */
                        boolean onlyActive = true;
                        for (CallSession o : registry.snapshot()) {
                            if (o != s && !o.isTerminal()) {
                                onlyActive = false;
                                break;
                            }
                        }
                        if (onlyActive) {
                            AudioRouteHelper.applyInitialRoute(appContext);
                        }
                    }
                    /* 通话音频模式（听筒发送小声问题的根治：见
                     * AudioRouteHelper.beginCommunicationMode 注释） */
                    AudioRouteHelper.beginCommunicationMode(appContext);
                }

                String view = computeViewState(s, state, lastStatus);
                if (view != null && !view.equals(s.callStateView)) {
                    log("[engine] call " + cid + " view "
                            + s.callStateView + " -> " + view);
                    s.callStateView = view;
                    handleViewSideEffects(s, view);
                }

                if (state == CALL_STATE_DISCONNECTED) {
                    /* 无剩余活跃通话则退出通话音频模式 */
                    boolean hasActive = false;
                    for (CallSession o : registry.snapshot()) {
                        if (o != s && !o.isTerminal()) {
                            hasActive = true;
                            break;
                        }
                    }
                    if (!hasActive) {
                        AudioRouteHelper.endCommunicationMode(appContext);
                    }
                    if (s.isTerminal()) {
                        onSessionTerminated(s);
                    } else {
                        /* 非映射终态兜底（理论不可达） */
                        s.callStateView = CallSession.STATE_TERMINATED;
                        onSessionTerminated(s);
                    }
                }
                notifySessionChanged(s);
            }
        });
    }

    void postAnswerSdp(final int cid, final String sdp) {
        post(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId(cid);
                /* 仅在本地 offer（INVITE / re-INVITE）在途时应用 answer。
                 * 每次 offer 都要应用其 answer，否则 PeerConnection 停在
                 * have-local-offer，后续对端 offer 的 SRD 全被拒。 */
                if (s == null || s.pc == null || !s.awaitingAnswer) {
                    return;
                }
                s.awaitingAnswer = false;
                log("[pjsua] 200 OK answer received ("
                        + (sdp != null ? sdp.length() : 0) + " bytes)");

                s.pc.setRemoteDescription(new SdpObserverBase(s) {
                    @Override
                    protected void onSetDone() {
                        log("[webrtc] SetRemoteDescription: OK");
                    }

                    @Override
                    protected void onFailed(String error) {
                        log("[webrtc] SetRemoteDescription: " + error);
                    }
                }, new SessionDescription(SessionDescription.Type.ANSWER,
                        sdp != null ? sdp : ""));
            }
        });
    }

    /**
     * 来电 INVITE（手动接听链）：缓存 offer 与头（NewStringUTF 已拷贝，
     * Java String 生命周期安全），置 IncomingTrying 等 callAnswer /
     * callReject；振铃（pjsua 自动 180）经 postCallState → IncomingRinging。
     */
    void postIncomingSdp(final int cid, final String sdp, final String requestId,
                         final String callerIdName, final String remoteNumber) {
        post(new Runnable() {
            @Override
            public void run() {
                if (registry.findByCallId(cid) != null) {
                    log("[ys] duplicate incoming event for call " + cid);
                    return;
                }
                CallSession s = registry.create(CallSession.DIRECTION_IN);
                if (s == null) {
                    /* 容量满：直接 486，避免对端干等（JS 侧本就限制 2 路） */
                    log("[engine] incoming call " + cid
                            + " dropped: MAX_CONCURRENT");
                    JniBridge.nativeRejectCall(cid);
                    return;
                }
                s.callId = cid;
                s.groupId = String.valueOf(cid);
                s.offerSdp = sdp != null ? sdp : "";
                s.requestId = requestId;
                s.callerIdName = callerIdName;
                s.accountName = callerIdName;
                s.remoteNumber = remoteNumber;
                s.pjsuaState = CALL_STATE_INCOMING;
                s.callStateView = CallSession.STATE_INCOMING_TRYING;

                log("[ys] incoming call " + cid + " (offer "
                        + s.offerSdp.length() + " bytes"
                        + (requestId != null ? ", X-Request-ID=" + requestId : "")
                        + (callerIdName != null
                                ? ", X-Nov-Caller-ID-Name=" + callerIdName : "")
                        + ") -> waiting for answer/reject");

                /* 来电铃声 + 振动（不摘麦克风；展示仲裁由上层 onIncomingCall 决定） */
                RingtoneHelper.playRingtone(appContext);

                if (callback != null) {
                    callback.onIncomingCall(s);
                }
                notifySessionChanged(s);
            }
        });
    }

    void postReinviteSdp(final int cid, final String sdp) {
        post(new Runnable() {
            @Override
            public void run() {
                CallSession s = registry.findByCallId(cid);
                if (s == null || s.pc == null) {
                    log("[webrtc] re-INVITE but session/PeerConnection is gone");
                    return;
                }
                /* SBC 接通后 100ms 内连发两个 re-INVITE：第二个 offer 到达
                 * 时前一个 answer 链可能仍在跑，新链的 answer 会撞上已被
                 * 推进的 INVITE 状态（库层拒绝）——丢弃，对端收不到应答
                 * 会重传 INVITE，届时链空闲再正常处理。 */
                if (s.answerPending && !s.answerSent) {
                    log("[webrtc] re-INVITE while previous answer in flight"
                            + " - dropping, peer will retransmit");
                    return;
                }
                /* glare：本地 re-INVITE offer 在途（have-local-offer）时
                 * SRD(offer) 会被 WebRTC 拒绝（wrong state）——同样丢弃
                 * 等重传。 */
                if (s.awaitingAnswer) {
                    log("[webrtc] re-INVITE collides with our pending offer"
                            + " (glare) - dropping, peer will retransmit");
                    return;
                }
                s.answerSent = false;
                log("[webrtc] re-INVITE offer ("
                        + (sdp != null ? sdp.length() : 0)
                        + " bytes), renegotiating");

                /* 对端 hold/resume 检测（§2.2 isOnHold）：offer 方向
                 * sendonly/inactive = 对端保持；sendrecv/缺省 = 恢复 */
                boolean remoteHold = detectRemoteHold(sdp);
                if (remoteHold != s.remoteHoldFlag) {
                    s.remoteHoldFlag = remoteHold;
                    s.holdStartTime = remoteHold
                            ? System.currentTimeMillis() : 0;
                    log("[webrtc] remote hold=" + remoteHold
                            + " (call " + cid + ")");
                    notifySessionChanged(s);
                }

                answerRemoteOffer(s, sdp != null ? sdp : "");
            }
        });
    }

    void postEngineLog(final int level, final String msg) {
        post(new Runnable() {
            @Override
            public void run() {
                if (callback != null) {
                    callback.onLog(level, msg);
                }
            }
        });
    }

    /* ------------------------------------------------------------------ */
    /* 视图状态映射（detail-design §2.1）                                  */
    /* ------------------------------------------------------------------ */

    /**
     * pjsua state/last_status → 会话视图状态；返回 null 表示保持当前视图
     * （CONNECTING 等过渡态）。
     */
    private String computeViewState(CallSession s, int state, int lastStatus) {
        switch (state) {
            case CALL_STATE_CALLING:
                return s.isIncoming()
                        ? CallSession.STATE_INCOMING_TRYING
                        : CallSession.STATE_TRYING;
            case CALL_STATE_EARLY:
                /* 呼出 180/183+SDP → Ringing；来电 180（pjsua 自动发）→
                 * IncomingRinging（canBeAnswered=true） */
                return s.isIncoming()
                        ? CallSession.STATE_INCOMING_RINGING
                        : CallSession.STATE_RINGING;
            case CALL_STATE_CONNECTING:
                /* 2xx 在途，CONFIRMED 紧随，不产生独立视图 */
                return null;
            case CALL_STATE_CONFIRMED:
                return s.isIncoming()
                        ? CallSession.STATE_INCOMING_ANSWERED
                        : CallSession.STATE_ESTABLISHED;
            case CALL_STATE_DISCONNECTED:
                if (s.isIncoming()) {
                    if (s.rejectRequested) {
                        return CallSession.STATE_INCOMING_REJECTED;
                    }
                    /* 用户接听过（answerRequested）的通话任何终结都是
                     * TERMINATED——从根上消除"已接听乐观态收到 Missed"
                     * 非法序列（曾致通话导航栈白屏；零候选超预算 hangup
                     * 路径的迟到 DISCONNECTED 同由此守卫
                     * 根治方案——此前在调用处置中间态的
                     * 写法在主线程串行模型下永不被回调观察到，无效） */
                    if (s.answerRequested) {
                        return CallSession.STATE_TERMINATED;
                    }
                    /* 从未接通即断（对端 CANCEL / 超时）= 未接来电 */
                    if (!CallSession.STATE_INCOMING_ANSWERED.equals(
                            s.callStateView)) {
                        return CallSession.STATE_INCOMING_MISSED;
                    }
                    return CallSession.STATE_TERMINATED;
                }
                /* 呼出终态按最后响应码分流 */
                if (lastStatus == 486 || lastStatus >= 600) {
                    return CallSession.STATE_BUSY;
                }
                /* 401=未授权(凭证拒) 403=禁用 407=代理认证重试超限 */
                if (lastStatus == 401 || lastStatus == 403
                        || lastStatus == 407) {
                    return CallSession.STATE_UNAUTHORIZED;
                }
                if (lastStatus == 487) {
                    /* 呼出取消（我方 CANCEL 后的最终响应） */
                    return CallSession.STATE_TERMINATED;
                }
                if (lastStatus >= 400 && lastStatus < 600) {
                    return CallSession.STATE_ERROR;
                }
                return CallSession.STATE_TERMINATED;
            default:
                return null;
        }
    }

    /** 视图变化副作用的收口（回铃音控制等） */
    private void handleViewSideEffects(CallSession s, String view) {
        if (s.isIncoming()) {
            return;
        }
        if (CallSession.STATE_RINGING.equals(view)) {
            RingtoneHelper.playBackTone();
        } else if (CallSession.STATE_ESTABLISHED.equals(view) || s.isTerminal()) {
            RingtoneHelper.stopBackTone();
        }
    }

    /** 对端 offer 方向检测：sendonly/inactive = hold */
    private static boolean detectRemoteHold(String sdp) {
        if (sdp == null) {
            return false;
        }
        /* 行级匹配（"a=sendonly" 非 "a=sendonlyr" 之类误配）：SIP SDP 中
         * 属性均为完整行，含 \r\n；直接子串判断已足够（demo 域无畸变 SDP） */
        return sdp.contains("a=sendonly") || sdp.contains("a=inactive");
    }

    /* ------------------------------------------------------------------ */
    /* WebRTC 初始化 / PeerConnection 建立（各会话独立）                    */
    /* ------------------------------------------------------------------ */

    private void ensureWebRtc(Context context) {
        if (factory != null || webrtcFailed) {
            return;
        }
        try {
            PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions.builder(appContext)
                            .createInitializationOptions());
            adm = JavaAudioDeviceModule.builder(appContext)
                    /* 硬件 AEC 恒关：听筒模式下
                     * 硬件 AEC（双麦波束降噪）过度抑制发送人声——对方听
                     * 到声音极小，切换扬声器触发路由重建后恢复（AEC 重
                     * 校准）。回声消除由 WebRTC 内置软件 AEC3 承担（不
                     * 依赖麦克风路由，稳定；对齐旧栈自有软件 AEC 的行为）。
                     * echoCancelEnabled 开关暂无独立生效点（本 aar 无软件
                     * AEC 单独开关 API），仅保留设置记忆。 */
                    .setUseHardwareAcousticEchoCanceler(false)
                    .createAudioDeviceModule();
            factory = PeerConnectionFactory.builder()
                    .setAudioDeviceModule(adm)
                    .createPeerConnectionFactory();
            log("[webrtc] PeerConnectionFactory ready");
        } catch (Throwable t) {
            /* aar 缺 jni_zero 绑定类时在此抛 NoClassDefFoundError：
             * 降级纯信令模式（注册/呼出控制信令仍可验证） */
            factory = null;
            adm = null;
            webrtcFailed = true;
            log("[webrtc] PeerConnectionFactory init FAILED: " + t
                    + " -> signaling-only mode (no media)");
            Log.e(TAG, "WebRTC init failed", t);
        }
    }

    /** 为会话建立独立 PeerConnection + 音频 track（每路通话一套） */
    private void setupPeerConnection(CallSession s) {
        if (factory == null || s.pc != null) {
            return;
        }

        /* 候选极简化：不配 STUN，仅收集 host 候选。旧结论
         * "云媒体网关只回包到 srflx——rtpengine（ICE-lite）
         * 按收包源地址回包（prflx 学习），host 候选直发 check 即可达；srflx 在对称 NAT 下本就无效且引入 STUN 依赖
         * 的失败面与 gathering 延迟（150-800ms）。网络切换恢复链同样
         * 走 prflx。
         * stunServers 配置链保留但不用于候选收集。 */
        PeerConnection.RTCConfiguration config =
                new PeerConnection.RTCConfiguration(
                        Collections.<PeerConnection.IceServer>emptyList());
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        /* 持续候选收集 + 仅 host 候选：rtpengine 按源地址学习（prflx），
         * host 直发 check 即可达公网媒体锚点，无需 STUN/srflx */
        config.continualGatheringPolicy =
                PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY;

        s.pc = factory.createPeerConnection(config, new SessionPcObserver(s));
        s.audioSource = factory.createAudioSource(new MediaConstraints());
        s.audioTrack = factory.createAudioTrack("pjsua-audio-" + s.sessionId,
                s.audioSource);
        try {
            /* 发送增益（m69 AudioSource 无 setVolume，挂 AudioTrack） */
            s.audioTrack.setVolume(micGain);
        } catch (Throwable ignored) {
        }
        s.pc.addTrack(s.audioTrack,
                Collections.singletonList("pjsua-stream-" + s.sessionId));
        applyTrackEnabled(s);
    }

    /** track 使能 = !mute && !hold（静音与保持都关本地发送） */
    private void applyTrackEnabled(CallSession s) {
        if (s.audioTrack != null) {
            s.audioTrack.setEnabled(!s.muteFlag && !s.holdFlag);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 呼出：ICE 收集完成（或看门狗超时）→ INVITE                          */
    /* ------------------------------------------------------------------ */

    /** localDescription 含全部候选（或看门狗到点带已有候选）→ 发 INVITE */
    private void sendInviteWithLocalSdp(CallSession s) {
        if (s.inviteSent || s.pc == null) {
            return;
        }
        SessionDescription desc = s.pc.getLocalDescription();
        if (desc == null) {
            return;
        }
        s.inviteSent = true;

        String filteredSdp = filterIpv6Candidates(desc.description);
        int newCallId = JniBridge.nativeMakeCall(accId, s.remoteNumber,
                filteredSdp);
        if (newCallId < 0) {
            log("[ys] ys_make_call_with_sdp failed");
            terminateSession(s, CallSession.STATE_ERROR);
            return;
        }
        s.callId = newCallId;
        /* groupId 不改写：保持 sessionId 稳定语义（见 callMake 注释） */
        s.awaitingAnswer = true;
        s.callStateView = CallSession.STATE_TRYING;   /* make_call 提交成功 */
        log("[ys] INVITE sent (call " + s.callId + ", offer "
                + filteredSdp.length() + " bytes)");
        notifySessionChanged(s);
    }

    /* ------------------------------------------------------------------ */
    /* offer -> answer 链（来电接听与 re-INVITE 共用）                      */
    /* ------------------------------------------------------------------ */

    /* SRD(offer) -> CreateAnswer -> SLD -> answerPending=true -> 等 ICE
     * （gathering complete 或 2s 看门狗）-> 200（answer 必须携带候选，
     * 服务器非 trickle，故 SLD 后不能立即发 200）。 */
    private void answerRemoteOffer(final CallSession s, String offerSdp) {
        if (s.pc == null) {
            return;
        }

        s.pc.setRemoteDescription(new SdpObserverBase(s) {
            @Override
            protected void onSetDone() {
                if (s.pc == null) {
                    return;
                }
                s.pc.createAnswer(new SdpObserverBase(s) {
                    @Override
                    protected void onCreated(SessionDescription answer) {
                        if (s.pc == null) {
                            return;
                        }
                        s.pc.setLocalDescription(new SdpObserverBase(s) {
                            @Override
                            protected void onSetDone() {
                                if (s.pc == null) {
                                    return;
                                }
                                s.answerPending = true;
                                log("[webrtc] answer set locally, "
                                        + "gathering ICE candidates...");
                                armGatherWatchdog(s);
                                /* gathering 可能已完成（re-INVITE 复用已收
                                 * 集候选）-> 立即发 */
                                if (s.pc.iceGatheringState()
                                        == PeerConnection.IceGatheringState.COMPLETE) {
                                    sendAnswerWithLocalSdp(s);
                                }
                            }

                            @Override
                            protected void onFailed(String error) {
                                log("[webrtc] SetLocalDescription FAILED: "
                                        + error);
                            }
                        }, answer);
                    }

                    @Override
                    protected void onFailed(String error) {
                        log("[webrtc] CreateAnswer FAILED: " + error);
                    }
                }, new MediaConstraints());
            }

            @Override
            protected void onFailed(String error) {
                log("[webrtc] SetRemoteDescription FAILED: " + error);
                /* offer 不可应答（如缺 DTLS fingerprint，服务器侧媒体
                 * 配置问题）：立即 486 终结来电并转拒接终态。否则 200
                 * 永不发、对端超时取消（603），JS 接听乐观态收到 Missed
                 * 的非法序列会导致通话导航栈异常 */
                if (s.isIncoming() && !s.isTerminal()
                        && (s.pjsuaState == CALL_STATE_INCOMING
                            || s.pjsuaState == CALL_STATE_EARLY)) {
                    log("[engine] incoming offer unacceptable -> reject 486");
                    /* rejectRequested 防迟到 DISCONNECTED 覆写 Missed（用户
                     * 已接听乐观态收到 Missed 致导航栈白屏——本分支曾缺失
                     * 该守卫，补齐）；失败仅日志乐观终结
                     * （终结经 terminateSession 收敛，#10） */
                    s.rejectRequested = true;
                    if (JniBridge.nativeRejectCall(s.callId) != 0) {
                        log("[engine] SRD 失败分支 reject 486 发送失败"
                                + "（本地乐观终结）call " + s.callId);
                    }
                    terminateSession(s, CallSession.STATE_INCOMING_REJECTED);
                }
            }
        }, new SessionDescription(SessionDescription.Type.OFFER, offerSdp));
    }

    /** 零候选保护作用域：呼入初始应答（振铃/早期窗口，200 未发过） */
    private boolean isIncomingInitialAnswer(CallSession s) {
        return s.isIncoming() && !s.isTerminal()
                && (s.pjsuaState == CALL_STATE_INCOMING
                    || s.pjsuaState == CALL_STATE_EARLY);
    }

    /** 用本地 answer（含已收集候选）发 200。 */
    private void sendAnswerWithLocalSdp(CallSession s) {
        if (s.answerSent || !s.answerPending || s.pc == null) {
            return;
        }
        SessionDescription desc = s.pc.getLocalDescription();
        if (desc == null) {
            return;
        }
        /* 零候选保护（见 ZERO_CANDIDATE_BUDGET_MS 注释）：仅呼入初始
         * 应答。延长等待期间看门狗周期性重走此处，候选到达即正常发送 */
        if (isIncomingInitialAnswer(s)
                && !desc.description.contains("a=candidate")) {
            long now = System.currentTimeMillis();
            if (s.zeroCandidateSince == 0) {
                s.zeroCandidateSince = now;
            }
            if (now - s.zeroCandidateSince < ZERO_CANDIDATE_BUDGET_MS) {
                /* 告警仅在零候选持续超过落盘窗后打：候选极简化（无
                 * STUN）下 gathering ~3ms 即 COMPLETE，而候选并入
                 * description 文本滞后数十 ms——COMPLETE 即查落在该窗口
                 * 属正常时序。首查静默，看门狗
                 * 重查（800ms 周期）仍零候选才告警 */
                if (now - s.zeroCandidateSince >= CANDIDATE_FLUSH_MS) {
                    log("[webrtc] answer 零候选，延长等待收集 (call "
                            + s.callId + ")");
                }
                armGatherWatchdog(s);
                return;
            }
            s.zeroCandidateSince = 0;
            /* 对齐 rejectInternal 三步守卫：
             * ① answerRequested 检查——初始应答链唯一入口 answerInternal
             *    先行置位，预算到期时恒为 true（除非未来新增非用户触发的
             *    应答布防点——hangup 分支为当前 100% 路径）；
             * ② 挂断终结前置 view=INCOMING_ANSWERED 作防覆写守卫：
             *    nativeHangup 引发的迟到 DISCONNECTED 在 TERMINAL_LINGER
             *    窗口内经 computeViewState 会把裸 TERMINATED 覆写成
             *    INCOMING_MISSED（已接听乐观态收到 Missed 的非法序列曾致
             *    通话导航栈白屏），view=ANSWERED 时幂等映射回 TERMINATED；
             * ③ 振铃期先停铃；④ 下方拒接分支（当前调用图不可达，防御
             *    未来布防点）设 rejectRequested 同理防覆写，失败保持
             *    标志本地乐观终结 */
            if (s.answerRequested) {
                log("[engine] answer 零候选超预算但用户已接听 "
                        + "-> hangup (call " + s.callId + ")");
                RingtoneHelper.stopRingtone();
                if (s.callId >= 0
                        && JniBridge.nativeHangup(s.callId) != 0) {
                    log("[ys] hangup " + s.callId
                            + " failed (零候选超预算路径)");
                }
                /* 迟到 DISCONNECTED 的防 Missed 覆写由 computeViewState 的
                 * answerRequested 守卫承担，
                 * 此处无需中间态赋值（串行模型下不会被观察到）；
                 * 终结经 terminateSession 收敛 */
                terminateSession(s, CallSession.STATE_TERMINATED);
                return;
            }
            log("[engine] answer 零候选超预算 -> reject 486 (call "
                    + s.callId + ")");
            RingtoneHelper.stopRingtone();
            s.rejectRequested = true;
            if (JniBridge.nativeRejectCall(s.callId) != 0) {
                log("[engine] reject 486 发送失败，本地乐观终结 (call "
                        + s.callId + ")");
            }
            terminateSession(s, CallSession.STATE_INCOMING_REJECTED);
            return;
        }
        s.zeroCandidateSince = 0;
        s.answerSent = true;
        s.answerPending = false;
        cancelGatherWatchdog(s);

        String filteredAns = filterIpv6Candidates(desc.description);
        if (JniBridge.nativeAnswerCall(s.callId, 200, filteredAns) == 0) {
            log("[ys] answered 200 (call " + s.callId + ", answer "
                    + filteredAns.length()
                    + " bytes, ICE candidates included)");
        } else {
            log("[ys] answer FAILED");
        }
    }

    /* ------------------------------------------------------------------ */
    /* hold/resume re-INVITE 链                                            */
    /* ------------------------------------------------------------------ */

    /** createOffer -> SLD -> （gathering complete 或 2s 看门狗）-> re-INVITE。
     * reason 仅用于日志区分（hold-resume / net-recovery ICE restart）。 */
    private void renegotiate(final CallSession s, String reason) {
        if (s.pc == null) {
            return;
        }
        s.pc.createOffer(new SdpObserverBase(s) {
            @Override
            protected void onCreated(SessionDescription sdp) {
                if (s.pc == null) {
                    return;
                }
                log("[webrtc] " + reason + " offer generated ("
                        + sdp.description.length() + " bytes)");
                s.pc.setLocalDescription(new SdpObserverBase(s) {
                    @Override
                    protected void onSetDone() {
                        if (s.pc == null) {
                            return;
                        }
                        s.reinvitePending = true;
                        log("[webrtc] " + reason + " offer set, "
                                + "gathering ICE candidates...");
                        armGatherWatchdog(s);
                        /* re-INVITE 复用已收集候选时 gathering 已完成，立即发 */
                        if (s.pc.iceGatheringState()
                                == PeerConnection.IceGatheringState.COMPLETE) {
                            sendReinviteWithLocalSdp(s);
                        }
                    }

                    @Override
                    protected void onFailed(String error) {
                        log("[webrtc] SetLocalDescription FAILED: " + error);
                        s.reinvitePending = false;
                    }
                }, sdp);
            }

            @Override
            protected void onFailed(String error) {
                log("[webrtc] CreateOffer FAILED: " + error);
                s.reinvitePending = false;
            }
        }, new MediaConstraints());
    }

    /** 用本地 offer（含已收集候选）发 re-INVITE。 */
    private void sendReinviteWithLocalSdp(CallSession s) {
        if (!s.reinvitePending || s.pc == null) {
            return;
        }
        SessionDescription desc = s.pc.getLocalDescription();
        if (desc == null) {
            return;
        }
        s.reinvitePending = false;
        cancelGatherWatchdog(s);

        String filteredReinvite = filterIpv6Candidates(desc.description);
        if (JniBridge.nativeReinviteCall(s.callId, filteredReinvite) == 0) {
            s.awaitingAnswer = true;
            log("[ys] re-INVITE sent (call " + s.callId + ", offer "
                    + filteredReinvite.length() + " bytes)");
        } else {
            log("[ys] re-INVITE FAILED");
        }
    }

    /* ------------------------------------------------------------------ */
    /* 网络切换恢复                                                        */
    /*                                                                     */
    /* 链路：NetworkMonitor 换网事件（防抖后）→ nativeHandleIpChange 启动  */
    /* 库层信令恢复（shutdown 死连接 + 账号 re-REGISTER + 通话 dialog 换   */
    /* transport）→ SHUTDOWN_TP 步完成后（不等 re-REGISTER，reg watch    */
    /* 同凭据 re-INVITE（ufrag 不变 + 新候选，ICE/DTLS 延续）→ answer    */
    /* 经 postAnswerSdp 应用。失败不挂断不重拨（R4）。                      */
    /* ------------------------------------------------------------------ */

    /** NetworkMonitor 换网事件落点（主线程，已防抖） */
    private void handleNetworkChanged(String reason) {
        if (!started) {
            return;
        }
        /* 换网事件上抛（Listeners.OnNetworkChangeDetected 通道：App 侧
         * 据此注入 X-NetworkChanged INVITE 头标记换网 re-INVITE） */
        if (callback != null) {
            post(new Runnable() {
                @Override
                public void run() {
                    if (callback != null) {
                        callback.onNetworkChanged(reason);
                    }
                }
            });
        }
        if (netRecoveryRunning) {
            /* 单飞：本轮进行中，标记重跑（双网竞态残余连发合并为
             * 下一轮，避免恢复风暴） */
            netRecoveryPendingRerun = true;
            log("[net-recovery] cycle running, rerun flagged: " + reason);
            return;
        }
        netRecoveryRunning = true;
        netRecoveryPendingRerun = false;
        netRecoveryStartMs = SystemClock.elapsedRealtime();

        int active = 0;
        for (CallSession s : registry.snapshot()) {
            if (s.callId >= 0 && s.pjsuaState == CALL_STATE_CONFIRMED
                    && !s.isTerminal()) {
                active++;
            }
        }
        log("[net-recovery] trigger: " + reason + ", confirmed calls="
                + active);

        if (JniBridge.nativeHandleIpChange() != 0) {
            log("[net-recovery] ys_handle_ip_change FAILED, abort");
            finishNetRecoveryCycle();
            return;
        }
        armIpChangeWatchdog();
    }

    /** JNI 回调入口（pjsua worker 线程）→ 主线程 */
    void postIpChangeProgress(final int step, final int status) {
        post(new Runnable() {
            @Override
            public void run() {
                if (!netRecoveryRunning) {
                    /* 无恢复周期在途（超时已收尾/监督轮）：仅日志 */
                    log("[net-recovery] ip-change step " + step
                            + " (no cycle, ignored)");
                    return;
                }
                log("[net-recovery] ip-change step " + step
                        + (status == 0 ? "" : " status=" + status));
                if (step == IP_CHANGE_STEP_SHUTDOWN_TP) {
                    /* 死连接已淘汰：立即媒体恢复（re-INVITE acquire 新建
                     * 连接，不等账号 re-REGISTER 结果——服务器对新连接
                     * 的响应慢，等它会把媒体恢复拖到 32s+）。账号注册
                     * 由 reg watch 兜底 */
                    cancelIpChangeWatchdog();
                    onIpChangeCompleted(false);
                } else if (step == IP_CHANGE_STEP_COMPLETED) {
                    cancelIpChangeWatchdog();
                    onIpChangeCompleted(false);
                }
            }
        });
    }

    private void armIpChangeWatchdog() {
        cancelIpChangeWatchdog();
        ipChangeWatchdog = new Runnable() {
            @Override
            public void run() {
                ipChangeWatchdog = null;
                onIpChangeCompleted(true);
            }
        };
        main.postDelayed(ipChangeWatchdog, IP_CHANGE_TIMEOUT_MS);
    }

    private void cancelIpChangeWatchdog() {
        if (ipChangeWatchdog != null) {
            main.removeCallbacks(ipChangeWatchdog);
            ipChangeWatchdog = null;
        }
    }

    /** 库层信令恢复完成（COMPLETED 回调或 5s 看门狗）：进入媒体恢复 */
    private void onIpChangeCompleted(boolean timeout) {
        if (!netRecoveryRunning) {
            return;
        }
        if (timeout) {
            log("[net-recovery] ip-change DONE timeout ("
                    + IP_CHANGE_TIMEOUT_MS + "ms), continuing with"
                    + " completed steps (reg self-heal continues)");
        } else {
            log("[net-recovery] ip-change done (signal "
                    + (SystemClock.elapsedRealtime() - netRecoveryStartMs)
                    + "ms)");
        }
        runMediaRecovery();
    }

    /** 对全部 CONFIRMED 会话逐路发起同凭据 re-INVITE（媒体恢复） */
    private void runMediaRecovery() {
        int restarted = 0;
        for (CallSession s : registry.snapshot()) {
            if (s.callId < 0 || s.pc == null || s.isTerminal()) {
                continue;
            }
            if (s.pjsuaState != CALL_STATE_CONFIRMED) {
                continue;
            }
            recoverMediaForSession(s);
            restarted++;
        }
        log("[net-recovery] media recovery started for " + restarted
                + " call(s)");
        finishNetRecoveryCycle();
    }

    /** 单路媒体恢复：同凭据 re-INVITE（见方法内方案 A 注释）。在途 offer
     *  时跳过本路——对端 offer 若在途，其 answer 链会自然处理新候选。 */
    private void recoverMediaForSession(final CallSession s) {
        if (s.awaitingAnswer || s.reinvitePending) {
            log("[net-recovery] call " + s.callId
                    + " skip: offer in flight (glare-safe)");
            return;
        }
        /* 网络切换媒体恢复：同凭据 re-INVITE（ufrag 不变 + 新候选）。
         * 对端不视为 ICE restart，ICE/DTLS 状态延续——媒体无缝恢复。
         * 媒体失败由 ICE FAILED 挂断兜底处理 */
        log("[net-recovery] recover call=" + s.callId
                + ": same-credentials re-INVITE with fresh candidates");
        renegotiate(s, "net-recovery");
    }

    /** 恢复周期收尾：计时日志 + pendingRerun 检查（竞态残余再走一轮） */
    private void finishNetRecoveryCycle() {
        long elapsed = SystemClock.elapsedRealtime() - netRecoveryStartMs;
        log("[net-recovery] cycle done (" + elapsed + "ms)");
        netRecoveryRunning = false;
        if (netRecoveryPendingRerun && started) {
            netRecoveryPendingRerun = false;
            handleNetworkChanged("rerun");
            return;
        }
        /* 恢复完成后注册仍未成功的（服务器半开连接占位场景）：启动
         * 注册监督，周期强制换连接重试 */
        startRegWatchIfNeeded();
    }

    /* ---------------- 注册监督（恢复兜底，见字段区注释） ---------------- */

    /** 恢复周期结束后启动监督：第一拍（间隔后）判断注册状态——切换
     *  触发的 re-REGISTER 若仍在途（最长 32s tsx 超时），届时已终结，
     *  lastRegStatus 准确；已 200 则监督自然结束。已在监督则跳过。 */
    private void startRegWatchIfNeeded() {
        if (!started || regWatchActive) {
            return;
        }
        regWatchActive = true;
        regWatchAttempts = 0;
        log("[net-recovery] reg watch armed (check in "
                + (REG_WATCH_INTERVAL_MS / 1000) + "s, retry up to "
                + REG_WATCH_MAX_ATTEMPTS + " attempts)");
        scheduleRegWatchTick();
    }

    private void scheduleRegWatchTick() {
        regWatchRunnable = new Runnable() {
            @Override
            public void run() {
                regWatchRunnable = null;
                if (!started || lastRegStatus == 200) {
                    regWatchActive = false;
                    return; /* 已成功或引擎已停：监督自然结束 */
                }
                /* 恢复周期进行中：顺延一拍，避免 ip_change 状态机重叠 */
                if (netRecoveryRunning) {
                    log("[net-recovery] reg watch deferred, recovery running");
                    scheduleRegWatchTick();
                    return;
                }
                regWatchAttempts++;
                if (regWatchAttempts > REG_WATCH_MAX_ATTEMPTS) {
                    log("[net-recovery] reg watch gave up after "
                            + REG_WATCH_MAX_ATTEMPTS
                            + " attempts, leaving to reg refresh/user");
                    regWatchActive = false;
                    return;
                }
                log("[net-recovery] reg watch attempt " + regWatchAttempts
                        + "/" + REG_WATCH_MAX_ATTEMPTS
                        + ": ip-change cycle (force new connection)");
                /* 全量 ip_change：tpmgr_shutdown_all 淘汰被服务器无视的
                 * 连接 + 新连接 re-REGISTER。间隔 > REGISTER tsx 超时
                 * （32s），保证上一轮终结后才发下一轮（上游对重叠的
                 * ip_change 只告警不阻止，重叠会错乱状态机） */
                JniBridge.nativeHandleIpChange();
                scheduleRegWatchTick();
            }
        };
        main.postDelayed(regWatchRunnable, REG_WATCH_INTERVAL_MS);
    }

    /** 注册成功（success=true）或引擎关闭时停止监督 */
    private void stopRegWatch(boolean success) {
        if (regWatchRunnable != null) {
            main.removeCallbacks(regWatchRunnable);
            regWatchRunnable = null;
        }
        if (success && regWatchActive) {
            log("[net-recovery] reg watch: registered OK (after "
                    + regWatchAttempts + " attempt(s))");
        }
        regWatchActive = false;
        regWatchAttempts = 0;
    }

    /* ------------------------------------------------------------------ */
    /* ICE gathering 看门狗（每会话独立，主线程）                           */
    /* ------------------------------------------------------------------ */

    private void armGatherWatchdog(final CallSession s) {
        armGatherWatchdog(s, GATHER_WATCHDOG_MS);
    }

    private void armGatherWatchdog(final CallSession s, long delayMs) {
        cancelGatherWatchdog(s);
        s.gatherWatchdog = new Runnable() {
            @Override
            public void run() {
                s.gatherWatchdog = null;
                gatherWatchdogFired(s);
            }
        };
        main.postDelayed(s.gatherWatchdog, delayMs);
    }

    private void cancelGatherWatchdog(CallSession s) {
        if (s.gatherWatchdog != null) {
            main.removeCallbacks(s.gatherWatchdog);
            s.gatherWatchdog = null;
        }
    }

    private void gatherWatchdogFired(CallSession s) {
        if (s.pc == null) {
            return;
        }
        if (s.answerPending) {
            if (!s.answerSent) {
                log("[webrtc] gathering watchdog fired -> answer 200 (call "
                        + s.callId + ")");
                sendAnswerWithLocalSdp(s);
            }
            return;
        }
        if (s.reinvitePending) {
            log("[webrtc] gathering watchdog fired -> re-INVITE (call "
                    + s.callId + ")");
            sendReinviteWithLocalSdp(s);
            return;
        }
        if (!s.inviteSent && !s.isIncoming()) {
            log("[webrtc] gathering watchdog fired -> INVITE");
            sendInviteWithLocalSdp(s);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 会话终结 / PeerConnection 释放                                       */
    /* ------------------------------------------------------------------ */

    /** 强制以指定终态结束会话（本地失败路径） */
    private void terminateSession(CallSession s, String view) {
        if (s.isTerminal()) {
            return;
        }
        s.callStateView = view;
        onSessionTerminated(s);
        notifySessionChanged(s);
    }

    /** 终态收口（幂等）：释放 WebRTC 资源、停提示音、登记延迟清除 */
    private void onSessionTerminated(final CallSession s) {
        if (s.terminatedAt != 0) {
            return;
        }
        long now = System.currentTimeMillis();
        s.terminatedAt = now;
        s.finalizeRemoveAt = now + CallSessionRegistry.TERMINAL_LINGER_MS;
        /* 零候选预算打点随终态清零（生命周期显式化
         * 防 re-INVITE 复用会话等路径沿用旧值提前耗尽） */
        s.zeroCandidateSince = 0;
        closePeerConnection(s, "");
        if (s.isIncoming()) {
            RingtoneHelper.stopRingtone();
        } else {
            RingtoneHelper.stopBackTone();
        }
        /* 终态短暂可见后从 callList 移除（§2.1）。移除后必须再推一次
         * 快照：JS 关闭通话页依赖收到空 callList（>0→0 触发面板关闭），
         * 只 purge 不通知 = JS 永远停在含终态的最后一个列表 → 界面卡死 */
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                registry.purgeExpired(System.currentTimeMillis());
                notifySessionChanged(s);
            }
        }, CallSessionRegistry.TERMINAL_LINGER_MS + 100);
    }

    private void closePeerConnection(CallSession s, String suffix) {
        cancelGatherWatchdog(s);
        if (s.pc != null) {
            s.pc.close();
            s.pc = null;
        }
        if (s.audioTrack != null) {
            s.audioTrack.dispose();
            s.audioTrack = null;
        }
        if (s.audioSource != null) {
            s.audioSource.dispose();
            s.audioSource = null;
        }
        log("[webrtc] PeerConnection closed (call " + s.callId + ")"
                + suffix);
    }

    /* ------------------------------------------------------------------ */
    /* 回调上抛 / 线程工具                                                  */
    /* ------------------------------------------------------------------ */

    private void notifySessionChanged(CallSession s) {
        if (callback != null) {
            callback.onCallSessionChanged(s);
        }
    }

    private void post(Runnable r) {
        main.post(r);
    }

    private static boolean isOnMain() {
        return Looper.myLooper() == Looper.getMainLooper();
    }

    /**
     * 主线程执行：在主线程时同步执行并返回结果；否则 post（返回 null，
     * 调用方按"已受理"处理 —— 正常路径 delegate 均在主线程调用）。
     */
    private <T> T runOnMain(java.util.concurrent.Callable<T> task) {
        if (isOnMain()) {
            try {
                return task.call();
            } catch (Exception e) {
                Log.e(TAG, "engine op failed", e);
                return null;
            }
        }
        log("[engine] WARNING: called off main thread - posted");
        final java.util.concurrent.Callable<T> ref = task;
        main.post(new Runnable() {
            @Override
            public void run() {
                try {
                    ref.call();
                } catch (Exception e) {
                    Log.e(TAG, "engine op failed", e);
                }
            }
        });
        return null;
    }

    /** runOnMain 的 void 版本（fire-and-forget 操作用） */
    private void runOnMain(final Runnable r) {
        if (isOnMain()) {
            r.run();
        } else {
            log("[engine] WARNING: called off main thread - posted");
            main.post(r);
        }
    }

    /** 过滤 IPv6 候选行（服务器不支持 IPv6，仅保留 IPv4 候选）。
     * 候选格式：a=candidate:<foundation> <component> <transport> <priority>
     * <address> <port> typ ...——address 字段含冒号即为 IPv6 */
    static String filterIpv6Candidates(String sdp) {
        if (sdp == null) {
            return null;
        }
        StringBuilder sb = new StringBuilder(sdp.length());
        for (String line : sdp.split("\n", -1)) {
            if (line.startsWith("a=candidate:")) {
                String[] fields = line.trim().split("\\s+");
                if (fields.length > 4 && fields[4].contains(":")) {
                    continue;
                }
            }
            sb.append(line).append('\n');
        }
        return sb.toString();
    }

    /** 引擎日志：全量进 logcat + 挂了 callback 则上抛（level 3=INFO） */
    private void log(String line) {
        Log.d(TAG, line);
        if (callback != null) {
            callback.onLog(3, line);
        }
    }

    /* ------------------------------------------------------------------ */
    /* SdpObserver 基类：四个回调统一 post 主线程（回调线程不确定），       */
    /* 并绑定所属会话                                                       */
    /* ------------------------------------------------------------------ */

    private abstract class SdpObserverBase implements SdpObserver {

        protected final CallSession session;

        SdpObserverBase(CallSession session) {
            this.session = session;
        }

        @Override
        public final void onCreateSuccess(final SessionDescription desc) {
            post(new Runnable() {
                @Override
                public void run() {
                    onCreated(desc);
                }
            });
        }

        @Override
        public final void onSetSuccess() {
            post(new Runnable() {
                @Override
                public void run() {
                    onSetDone();
                }
            });
        }

        @Override
        public final void onCreateFailure(final String error) {
            post(new Runnable() {
                @Override
                public void run() {
                    onFailed(error);
                }
            });
        }

        @Override
        public final void onSetFailure(final String error) {
            post(new Runnable() {
                @Override
                public void run() {
                    onFailed(error);
                }
            });
        }

        protected void onCreated(SessionDescription desc) {
        }

        protected void onSetDone() {
        }

        protected void onFailed(String error) {
        }
    }

    /* ------------------------------------------------------------------ */
    /* PeerConnection.Observer（每会话一个，回调统一 post 主线程）          */
    /* ------------------------------------------------------------------ */

    private class SessionPcObserver implements PeerConnection.Observer {

        private final CallSession session;

        SessionPcObserver(CallSession session) {
            this.session = session;
        }

        @Override
        public void onSignalingChange(PeerConnection.SignalingState newState) {
        }

        @Override
        public void onIceConnectionChange(
                final PeerConnection.IceConnectionState newState) {
            post(new Runnable() {
                @Override
                public void run() {
                    log("[ice-conn] call " + session.callId + " "
                            + iceConnName(newState));
                }
            });
        }

        @Override
        public void onIceConnectionReceivingChange(boolean receiving) {
        }

        @Override
        public void onIceGatheringChange(
                final PeerConnection.IceGatheringState newState) {
            post(new Runnable() {
                @Override
                public void run() {
                    log("[ice-gather] call " + session.callId + " " + newState);
                    if (newState == PeerConnection.IceGatheringState.COMPLETE) {
                        cancelGatherWatchdog(session);
                        if (session.answerPending) {
                            sendAnswerWithLocalSdp(session);
                        } else if (session.reinvitePending) {
                            sendReinviteWithLocalSdp(session);
                        } else {
                            sendInviteWithLocalSdp(session);
                        }
                    }
                }
            });
        }

        @Override
        public void onIceCandidate(final IceCandidate candidate) {
            /* 首个候选（host）到达即触发发送（CANDIDATE_FLUSH_MS 落盘窗，
             * 不等 srflx/COMPLETE——host-only 配对依据见
             * GATHER_WATCHDOG_MS 注释） */
            post(new Runnable() {
                @Override
                public void run() {
                    armGatherWatchdog(session, CANDIDATE_FLUSH_MS);
                }
            });
        }

        @Override
        public void onIceCandidatesRemoved(IceCandidate[] candidates) {
        }

        @Override
        public void onAddStream(MediaStream stream) {
        }

        @Override
        public void onRemoveStream(MediaStream stream) {
        }

        @Override
        public void onDataChannel(DataChannel dataChannel) {
        }

        @Override
        public void onRenegotiationNeeded() {
        }

        @Override
        public void onConnectionChange(
                final PeerConnection.PeerConnectionState newState) {
            post(new Runnable() {
                @Override
                public void run() {
                    log("[pc-state] call " + session.callId + " "
                            + pcStateName(newState));
                }
            });
        }
    }

    /* ------------------------------------------------------------------ */
    /* 状态名（对齐 demo/iOS 日志文案）                                     */
    /* ------------------------------------------------------------------ */

    private static String callStateName(int state) {
        switch (state) {
            case CALL_STATE_NULL:
                return "NULL";
            case CALL_STATE_CALLING:
                return "CALLING";
            case CALL_STATE_INCOMING:
                return "INCOMING";
            case CALL_STATE_EARLY:
                return "EARLY";
            case CALL_STATE_CONNECTING:
                return "CONNECTING";
            case CALL_STATE_CONFIRMED:
                return "CONFIRMED";
            case CALL_STATE_DISCONNECTED:
                return "DISCONNECTED";
            default:
                return "?";
        }
    }

    private static String iceConnName(PeerConnection.IceConnectionState state) {
        switch (state) {
            case NEW:
                return "new";
            case CHECKING:
                return "checking";
            case CONNECTED:
                return "connected";
            case COMPLETED:
                return "completed (ICE+DTLS)";
            case FAILED:
                return "FAILED";
            case DISCONNECTED:
                return "disconnected";
            case CLOSED:
                return "closed";
            default:
                return "?";
        }
    }

    private static String pcStateName(PeerConnection.PeerConnectionState state) {
        switch (state) {
            case NEW:
                return "new";
            case CONNECTING:
                return "connecting";
            case CONNECTED:
                return "CONNECTED";
            case DISCONNECTED:
                return "disconnected";
            case FAILED:
                return "FAILED";
            case CLOSED:
                return "closed";
            default:
                return "?";
        }
    }
}
