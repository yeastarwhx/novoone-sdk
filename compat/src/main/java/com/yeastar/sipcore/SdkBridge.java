package com.yeastar.sipcore;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.Ringtone;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.telecom.CallAudioState;
import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;

import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import cz.acrobits.ali.AndroidUtil;
import cz.acrobits.libsoftphone.data.AudioRoute;
import cz.acrobits.libsoftphone.data.Call;
import cz.acrobits.libsoftphone.data.RegistrationState;
import cz.acrobits.libsoftphone.event.CallEvent;
import cz.acrobits.libsoftphone.event.Event;
import cz.acrobits.libsoftphone.event.MessageEvent;
import cz.acrobits.libsoftphone.event.RemoteUser;
import cz.acrobits.libsoftphone.event.TimePoint;
import cz.acrobits.libsoftphone.support.Listeners;
import cz.acrobits.libsoftphone.support.lifecycle.LifecycleTracker;
import cz.acrobits.libsoftphone.telecom.TelecomUtil;

/**
 * Acrobits 兼容门面 → 自研引擎（:sip-core SipWebrtcEngine）桥接核心。
 *
 * 位于 com.yeastar.sipcore 包以访问 {@link CallSession#sessionId}
 * （包私有字段；eventId = sessionId 为身份契约）。
 *
 * 职责：
 * 1. 引擎生命周期（init / respawn / shutdown / transport 重建）
 * 2. 账号（AccountXml 解析 → accountRegister；SharedPreferences 持久化，
 *    冷启动自动恢复——对齐 Acrobits 账号自恢复语义）
 * 3. 事件桥（EngineCallback → Listeners 分发 + Telecom Connection 同步）
 * 4. 状态映射（CallSession.STATE_* → Call.State）
 * 5. transients 存储（按 eventId，ConcurrentHashMap——跨回调 CallEvent
 *    实例的数据通道）
 * 6. 统计轮询（getStats 1s 缓存 → CallStatistics/MediaStatus）
 *
 * 线程模型：引擎回调恒主线程；App 侧调用经 executor 已在主线程；
 * SdkBridge 自身不再二次 post（引擎方法自带 runOnMain 兜底）。
 */
public final class SdkBridge implements EngineCallback {

    private static final String TAG = "Acrobits.SdkBridge";

    private static final String PREFS = "acrobits_compat";
    private static final String KEY_USERNAME = "acc_username";
    private static final String KEY_PASSWORD = "acc_password";
    private static final String KEY_HOST = "acc_host";
    private static final String KEY_PROXY = "acc_proxy";
    private static final String KEY_AUTHUSER = "acc_authuser";
    private static final String KEY_DISPLAYNAME = "acc_displayname";
    private static final String KEY_EXPIRES = "acc_expires";
    private static final String KEY_TRANSPORT = "acc_transport";
    private static final String KEY_PUSH_REPORT_URL = "acc_push_report_url";
    private static final String KEY_PUSH_REPORT_HEADERS = "acc_push_report_headers";
    private static final String KEY_ACCOUNT_ID = "acc_account_id";

    /** 引擎销毁→重建的间隔（对齐 sdk 模块 restartEngineAndRegister 节奏） */
    private static final long ENGINE_RESTART_DELAY_MS = 1500;

    /** 统计轮询周期（App 契约：1s） */
    private static final long STATS_POLL_MS = 1000;

    /* Telecom 桥接 */

    /** 上报 extras 携带的 eventId 键（pending 槽配对键） */
    private static final String EXTRA_EVENT_ID = "cz.acrobits.libsoftphone.eventId";

    /** 运行期连续异常熔断阈值（同一进程连续 3 次即 disable） */
    private static final int TELECOM_FAILURE_TRIP = 3;

    /** 终态连接 destroy 延迟（先 setDisconnected 即时更新系统 UI，
     *  destroy + 移表延迟收尾） */
    private static final long TELECOM_TEARDOWN_DELAY_MS = 1500;

    /** self-managed 并发连接上限（对齐系统侧容量；旧实现单连接上限是
     *  "第二通来电蓝牙不响铃/无法接听"根因——通话中再来电直接被拒建连接） */
    private static final int MAX_SELF_MANAGED_CONNECTIONS = 5;

    private static volatile SdkBridge sInstance;

    public static SdkBridge get() {
        if (sInstance == null) {
            synchronized (SdkBridge.class) {
                if (sInstance == null) {
                    sInstance = new SdkBridge();
                }
            }
        }
        return sInstance;
    }

    private final SipWebrtcEngine mEngine = SipWebrtcEngine.getInstance();
    private final Handler mMain = new Handler(Looper.getMainLooper());

    /* 观察者（Instance.setObserver 设置；分发目标） */
    private volatile Listeners mObserver;

    /* transients：eventId → Dict（跨 CallEvent 实例存续） */
    private final ConcurrentHashMap<Long, cz.acrobits.ali.Json.Dict> mTransients =
            new ConcurrentHashMap<Long, cz.acrobits.ali.Json.Dict>();

    /* 事件分发去重：已发过 OnNewEvent/OnNewCall 的会话 */
    private final ConcurrentHashMap<Long, Boolean> mAnnounced =
            new ConcurrentHashMap<Long, Boolean>();

    /* 上次分发的 hold 状态（变化才发 OnCallHoldStateChanged） */
    private final ConcurrentHashMap<Long, Boolean> mLastLocalHold =
            new ConcurrentHashMap<Long, Boolean>();
    private final ConcurrentHashMap<Long, Boolean> mLastRemoteHold =
            new ConcurrentHashMap<Long, Boolean>();

    /* 统计缓存：eventId → 最近一次 getStats 快照 */
    private final ConcurrentHashMap<Long, SipWebrtcEngine.CallQualityData> mStats =
            new ConcurrentHashMap<Long, SipWebrtcEngine.CallQualityData>();

    /* Telecom：eventId → Connection（状态回写 + 路由协同）；音频路由回调宿主 */
    private final ConcurrentHashMap<Long, Connection> mTelecomConnections =
            new ConcurrentHashMap<Long, Connection>();
    private volatile Connection mAudioRoutingBoundConnection;
    private volatile cz.acrobits.libsoftphone.telecom.ConnectionService mAudioRoutingService;

    /**
     * 待消费的来电事件（单槽：addNewIncomingCall 前写入，
     * onCreateIncomingConnection 经 extractWaitingCall 消费；新来电覆盖旧值）。
     * AtomicReference.getAndSet(null) 原子消费——onCreateIncomingConnection
     * 由 Telecom binder 线程回调（不保证与主线程写入同线程），check-then-act
     * 读清在并发回调下可能双消费同一槽
     */
    private final AtomicReference<CallEvent> mPendingIncomingCall = new AtomicReference<>();

    /**
     * 已上报的 eventId 集合（上报幂等门）：上报到连接入表之间存在窗口
     * （Telecom 绑定异步），仅判"连接是否存在"会重复 addNewIncomingCall
     * （产生系统侧孤儿连接）。终态与连接拆除时移除
     */
    private final Set<Long> mReportedCallIds = ConcurrentHashMap.newKeySet();

    /** Telecom 桥接降级标志（注册失败/运行期熔断后本进程内整体静默） */
    private volatile boolean mTelecomDisabled;

    /** initTelecom 完成标志（幂等门） */
    private volatile boolean mTelecomInitialized;

    /** 运行期连续异常计数（成功处理一次事件即清零；线程：主线程 + binder） */
    private final AtomicInteger mTelecomFailureStreak = new AtomicInteger();


    /* 全局静音镜像（App 契约：Audio.isMuted 全局语义） */
    private volatile boolean mMuted;

    /* 自定义来电铃声（observer 提供，替代引擎默认铃声） */
    private volatile Ringtone mCustomRingtone;

    /* 日志缓冲 + 自定义 Sink（Instance.Log 通道） */
    private static final int LOG_LIMIT = 256 * 1024;
    private final StringBuilder mLogBuffer = new StringBuilder();
    private volatile OutputStream mLogSink;

    /* 账号快照（重启引擎后重注册 / 冷恢复） */
    private volatile AccountSnapshot mAccount = new AccountSnapshot();

    private SdkBridge() {
    }

    /** SDK 初始化（Instance.init）：上下文 + Activity 追踪 */
    public void init(Context context) {
        Context app = context != null ? context.getApplicationContext() : null;
        if (app instanceof android.app.Application) {
            LifecycleTracker.install((android.app.Application) app);
        }
        /* 引擎启动延后到账号注册（transport 由账号参数决定）；
         * 冷恢复：进程重启后账号从持久化快照恢复（对齐 Acrobits 自恢复） */
        restoreAccountSnapshot(app);
        initTelecom(app);
    }

    public void setObserver(Listeners observer) {
        mObserver = observer;
    }


    public SipWebrtcEngine engine() {
        return mEngine;
    }

    /* ------------------------------------------------------------------ */
    /* 拨号（Events.post → engine.callMake）                               */
    /* ------------------------------------------------------------------ */

    /**
     * 呼出事件提交：解析号码（remoteUser.genericUri）与 requestId
     * （transients["requestId"]，App 在 makeCall 时写入）→ engine.callMake。
     * 成功后把事件的 transients 挂入中央存储（eventId = sessionId）。
     */
    public boolean postCallEvent(CallEvent event) {
        if (event == null || event.remoteUser == null) {
            return false;
        }
        String number = event.remoteUser.genericUri;
        if (number == null || number.trim().isEmpty()) {
            return false;
        }
        String requestId = null;
        try {
            if (event.transients != null) {
                requestId = event.transients.getString("requestId").orElse(null);
            }
        } catch (Throwable ignored) {
        }
        long sessionId = mEngine.callMake(number.trim(), requestId);
        if (sessionId <= 0) {
            return false;
        }
        event.setEventId(sessionId);
        if (event.transients != null) {
            mTransients.put(sessionId, event.transients);
        }
        /* 去电 Telecom 上报延迟到对方振铃/接听时（onCallSessionChanged 的
         * Trying/Ringing 观测点）——postCallEvent 时通话未建立，立即上报
         * 会被系统清理（ConnectionService 3ms 即 destroy）*/
        /* 全局静音镜像应用到新会话 */
        if (mMuted) {
            CallSession s = findSession(sessionId);
            if (s != null && s.callId >= 0) {
                mEngine.callMute(s.callId, true);
            }
        }
        return true;
    }

    /* ------------------------------------------------------------------ */
    /* 会话 ↔ 事件                                                          */
    /* ------------------------------------------------------------------ */

    /** eventId（= sessionId）定位引擎会话；不存在返回 null */
    public CallSession findSession(long eventId) {
        if (eventId <= 0) {
            return null;
        }
        for (CallSession s : mEngine.snapshotCalls()) {
            if (s.sessionId == eventId) {
                return s;
            }
        }
        return null;
    }

    /** 引擎会话 → CallEvent 包装（每次新实例，transients 走中央存储） */
    public CallEvent wrapEvent(CallSession session) {
        CallEvent event = new CallEvent();
        event.setEventId(session.sessionId);
        event.accountId = 0;
        RemoteUser user = new RemoteUser();
        user.displayName = displayNameOf(session);
        user.genericUri = uriOf(session);
        event.remoteUser = user;
        event.addRemoteUser(user);
        event.setDirection(session.isIncoming()
                ? Event.Direction.INCOMING : Event.Direction.OUTGOING);
        if (session.callStartTime > 0) {
            event.timeEstablished = new TimePoint(session.callStartTime);
        }
        event.transients = transientsFor(session.sessionId);
        return event;
    }

    /** 会话显示名：来电 X-Nov-Caller-ID-Name > 账号显示名 > 号码 */
    private static String displayNameOf(CallSession s) {
        if (s.callerIdName != null && !s.callerIdName.isEmpty()) {
            return s.callerIdName;
        }
        if (s.accountName != null && !s.accountName.isEmpty()
                && !s.accountName.equals(s.remoteNumber)) {
            return s.accountName;
        }
        return s.remoteNumber;
    }

    /** 会话 URI：来电 "nx:{number}"（App 端取冒号后段），呼出裸号码 */
    private static String uriOf(CallSession s) {
        if (s.isIncoming()) {
            return "nx:" + (s.remoteNumber != null ? s.remoteNumber : "");
        }
        return s.remoteNumber != null ? s.remoteNumber : "";
    }

    /** eventId 的 transients（get-or-create） */
    public cz.acrobits.ali.Json.Dict transientsFor(long eventId) {
        cz.acrobits.ali.Json.Dict dict = mTransients.get(eventId);
        if (dict == null) {
            dict = new cz.acrobits.ali.Json.Dict();
            cz.acrobits.ali.Json.Dict prev = mTransients.putIfAbsent(eventId, dict);
            if (prev != null) {
                dict = prev;
            }
        }
        return dict;
    }

    /* ------------------------------------------------------------------ */
    /* 状态映射（CallSession.STATE_* → Call.State）                        */
    /* ------------------------------------------------------------------ */

    public Call.State mapState(CallSession s) {
        String v = s.callStateView;
        if (CallSession.STATE_TRYING.equals(v)) {
            return Call.State.Trying;
        }
        if (CallSession.STATE_RINGING.equals(v)) {
            return Call.State.Ringing;
        }
        if (CallSession.STATE_ESTABLISHED.equals(v)) {
            return Call.State.Established;
        }
        if (CallSession.STATE_INCOMING_TRYING.equals(v)) {
            return Call.State.IncomingTrying;
        }
        if (CallSession.STATE_INCOMING_RINGING.equals(v)) {
            return Call.State.IncomingRinging;
        }
        if (CallSession.STATE_INCOMING_ANSWERED.equals(v)) {
            /* 引擎来电接通后 callStateView 停留在 IncomingAnswered（无独立
             * Established 转换）。对齐 Acrobits（App 零改动）：映射为
             * Established——原始 JS 收到 Established 才启动计时/激活按钮 */
            return Call.State.Established;
        }
        if (CallSession.STATE_INCOMING_REJECTED.equals(v)) {
            return Call.State.IncomingRejected;
        }
        if (CallSession.STATE_INCOMING_MISSED.equals(v)) {
            return Call.State.IncomingMissed;
        }
        if (CallSession.STATE_BUSY.equals(v)) {
            return Call.State.Error;
        }
        if (CallSession.STATE_UNAUTHORIZED.equals(v)) {
            return Call.State.Error;
        }
        if (CallSession.STATE_ERROR.equals(v)) {
            return Call.State.Error;
        }
        /* 正常终态（挂断/对方挂断）：保持当前状态不映射为 Error——
         * 通话从 getActive() 消失即终态信号（Acrobits 无独立 Disconnected
         * 态；映射 Error 会让 App 弹"通话异常"对话框）。isTerminal
         * 判定在 App 侧经 closeTerminalCalls 收口 */
        if (CallSession.STATE_TERMINATED.equals(v)) {
            return Call.State.Established; /* 保持 Established，由 getActive
                                             * 排除驱动终态处理 */
        }
        return Call.State.Error;
    }

    /* ------------------------------------------------------------------ */
    /* EngineCallback 实现（引擎主线程回调 → Listeners 分发）               */
    /* ------------------------------------------------------------------ */

    @Override
    public void onIncomingCall(CallSession session) {
        CallEvent event = wrapEvent(session);

        /* observer 自定义铃声：取到即停引擎默认铃声改播 observer 铃声
         * （音量键静音链路：NovoSilenceInterceptor 停的就是这只会话铃声） */
        Listeners observer = mObserver;
        if (observer != null) {
            try {
                Ringtone custom = observer.getRingtone(event);
                if (custom != null) {
                    RingtoneHelper.stopRingtone();
                    mCustomRingtone = custom;
                    custom.play();
                }
            } catch (Throwable t) {
                android.util.Log.w(TAG, "observer ringtone failed: " + t);
            }
        }

        /* Telecom 来电上报（self-managed PhoneAccount 已注册时）：
         * 系统绑定 App 的 ConnectionService → onCreateIncomingConnection
         * → extractWaitingCall 取回本事件 */
        reportIncomingToTelecom(event);

        dispatch(event, mapState(session));
    }

    @Override
    public void onCallSessionChanged(CallSession session) {
        CallEvent event = wrapEvent(session);
        /* 去电 Telecom 上报（对方振铃/接听时——postCallEvent 时上报会被
         * 系统立即清理 ConnectionService，延迟到状态观测点对齐来电时序） */
        if (!session.isIncoming()
            && !session.isTerminal()
            && !mReportedCallIds.contains(session.sessionId)) {
            String v = session.callStateView;
            if (CallSession.STATE_RINGING.equals(v)
                || CallSession.STATE_ESTABLISHED.equals(v)) {
                reportOutgoingToTelecom(event, session.remoteNumber);
            }
        }
        dispatch(event, mapState(session));
        ensureStatsPolling();
    }

    /** 统一事件分发：OnNewEvent/OnNewCall（首次）→ OnCallStateChanged →
     *  OnCallHoldStateChanged（hold 变化）→ Telecom Connection 同步 */
    private void dispatch(CallEvent event, Call.State state) {
        Listeners observer = mObserver;
        if (observer == null) {
            return;
        }
        long id = event.getEventId();
        boolean first = mAnnounced.putIfAbsent(id, Boolean.TRUE) == null;

        if (first) {
            try {
                observer.dispatchNewEvent(event);
            } catch (Throwable ignored) {
            }
            try {
                observer.dispatchNewCall(event);
            } catch (Throwable ignored) {
            }
        }
        observer.dispatchCallStateChanged(event, state);

        /* hold 变化 → OnCallHoldStateChanged + OnMediaStatusChanged */
        CallSession session = findSession(id);
        if (session != null) {
            boolean local = session.holdFlag;
            boolean remote = session.remoteHoldFlag;
            Boolean lastLocal = mLastLocalHold.put(id, local);
            Boolean lastRemote = mLastRemoteHold.put(id, remote);
            if ((lastLocal == null || lastLocal != local)
                    || (lastRemote == null || lastRemote != remote)) {
                observer.dispatchCallHoldStateChanged(event,
                        new Call.HoldStates(
                                local ? Call.HoldState.Held : null,
                                remote ? Call.HoldState.Held : null));
            }
        }

        /* 离开振铃期：停 observer 自定义铃声 */
        if (mCustomRingtone != null && !isRingingState(state)) {
            stopCustomRingtone();
        }

        /* 终态清理：分发滞留后由 Registry purge，本地账本同步。
         * 终态判定以会话为准——Terminated 映射保持 Established（App 契约），
         * Call.State.isTerminal() 不可见，仅靠映射态会导致本地账本与
         * Telecom 连接永不清理（幽灵连接根因） */
        boolean terminal = state.isTerminal()
                || (session != null && session.isTerminal());
        if (terminal) {
            scheduleTerminalCleanup(id);
        }

        /* Telecom Connection 同步：终态专路拆除（防幽灵连接阻塞后续上报），
         * 非终态幂等状态映射（含 hold 与路由协同） */
        if (terminal) {
            teardownConnection(id, session, state);
        } else {
            syncConnectionState(session, state);
        }
    }

    private static boolean isRingingState(Call.State state) {
        return state == Call.State.IncomingTrying || state == Call.State.IncomingRinging;
    }

    private void stopCustomRingtone() {
        Ringtone rt = mCustomRingtone;
        mCustomRingtone = null;
        if (rt != null) {
            try {
                rt.stop();
            } catch (Throwable ignored) {
            }
        }
    }

    private void scheduleTerminalCleanup(final long id) {
        mMain.postDelayed(new Runnable() {
            @Override
            public void run() {
                mAnnounced.remove(id);
                mLastLocalHold.remove(id);
                mLastRemoteHold.remove(id);
                mStats.remove(id);
                mTelecomConnections.remove(id);
                /* transients 保留至会话从 Registry 移除后清除（App 的
                 * closeTerminalCalls / refresh 链可能在终态窗口内读取） */
                CallSession s = findSession(id);
                if (s == null) {
                    mTransients.remove(id);
                }
            }
        }, 3000);
    }

    @Override
    public void onRegisterState(final int status, String text) {
        if (status == 200) {
            /* 注册成功副作用（不依赖 observer）：token 补报 + 前台服务
             * 就位（划掉任务 un-REGISTER 窗口的载体） */
            PushTokenReporter.onRegistered();
            SipForegroundService.start();
        }
        Listeners observer = mObserver;
        if (observer == null) {
            return;
        }
        final RegistrationState state;
        if (status == 200) {
            state = RegistrationState.Registered;
        } else if (status == 401 || status == 403 || status == 407) {
            state = RegistrationState.RegistrationFailed;
        } else if (status >= 400 && status < 700) {
            state = RegistrationState.RegistrationFailed;
        } else {
            state = RegistrationState.Registering;
        }
        String accountId = mAccount.id;
        observer.dispatchRegistrationStateChanged(accountId != null ? accountId : "0", state);
    }

    @Override
    public void onLog(int level, String msg) {
        appendLog(msg);
    }

    /* ------------------------------------------------------------------ */
    /* 引擎生命周期 + 账号                                                   */
    /* ------------------------------------------------------------------ */

    /** 账号快照（注册参数 + 持久化字段） */
    public static final class AccountSnapshot {
        public String id;
        public String username;
        public String password;
        public String host;
        public String proxy;
        public String authUser;
        public String displayName;
        public int expires;
        public String transport = "tcp";
        /* push token 上报配置（AccountXml pushTokenReporter* 字段，App 创建
         * 账户时写入；上报由 SDK 内置 PushTokenReporter 完成） */
        public String pushTokenReporterUrl;
        public String pushTokenReporterCustomHeaders;
    }

    /** AccountXml → 注册（含引擎启动 / transport 重建 / 持久化） */
    public int saveAccount(cz.acrobits.libsoftphone.account.AccountXml accountXml) {
        if (accountXml == null || accountXml.xml == null) {
            return -1;
        }
        AccountSnapshot snap = new AccountSnapshot();
        snap.id = accountXml.xml.getAttribute(cz.acrobits.libsoftphone.data.Account.Attributes.ID);
        snap.username = accountXml.getString("username");
        snap.password = accountXml.getString("password");
        snap.host = accountXml.getString("host");
        snap.proxy = accountXml.getString("outboundProxy_host");
        snap.authUser = emptyToNull(accountXml.getString("authUsername"));
        snap.displayName = emptyToNull(accountXml.getString("displayName"));
        try {
            snap.expires = Integer.parseInt(
                    accountXml.getString("expires") != null ? accountXml.getString("expires") : "0");
        } catch (NumberFormatException e) {
            snap.expires = 0;
        }
        String rawTransport = accountXml.getString("transport");
        snap.transport = normalizeTransport(rawTransport);
        snap.pushTokenReporterUrl = emptyToNull(accountXml.getString("pushTokenReporterUrl"));
        snap.pushTokenReporterCustomHeaders =
                emptyToNull(accountXml.getString("pushTokenReporterCustomHeaders"));
        mAccount = snap;
        persistAccountSnapshot();
        return registerCurrentAccount();
    }

    private static String emptyToNull(String v) {
        return v == null || v.isEmpty() ? null : v;
    }

    /** transport 归一：tls→tcp 降级（引擎交付形态仅 udp/tcp），未知回退 tcp */
    private static String normalizeTransport(String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return "tcp";
        }
        String t = raw.trim().toLowerCase();
        if ("udp".equals(t)) {
            return "udp";
        }
        /* tls 降级 tcp（与 :sdk 模块 AccountDelegate.normalizeTransport 对齐） */
        return "tcp";
    }

    private int transportToEngine(String transport) {
        return "udp".equals(transport)
                ? SipWebrtcEngine.TRANSPORT_UDP : SipWebrtcEngine.TRANSPORT_TCP;
    }

    /* 注册防重入标记（冷启动恢复 + App createAccount/refreshAccounts 并发
     * 调 registerCurrentAccount 时，后到的调用会 unregister 掉前一次正在
     * 进行的注册——导致 accId 被置 -1） */
    private final java.util.concurrent.atomic.AtomicBoolean mRegisterInFlight =
            new java.util.concurrent.atomic.AtomicBoolean(false);
    /* 已成功注册的账号指纹（username@host），同账号重复调直接跳过 */
    private volatile String mRegisteredFingerprint;

    /** 按当前账号快照注册（引擎未启动则启动；transport 变更则重建） */
    public int registerCurrentAccount() {
        AccountSnapshot snap = mAccount;
        if (snap == null || snap.username == null || snap.username.isEmpty()
                || snap.host == null || snap.host.isEmpty()) {
            android.util.Log.w(TAG, "registerCurrentAccount: no usable account snapshot");
            return -1;
        }
        /* 同账号已注册：跳过（App 的 createAccount/refreshAccounts 多路径
         * 都会到达这里，同账号反复 unregister+register 互相残杀）。
         * 须同时校验引擎真实注册态：划掉任务的优雅注销（un-REGISTER）直调
         * engine.accountUnregister 不经过 SdkBridge（指纹仍在）但 accId 已
         * 置 -1——FCM 唤醒（wakeupByPush → 此处）必须重注册才能随 REGISTER
         * 带出推送三头，跳过会导致服务器不下发 INVITE（推送唤醒静默失效） */
        String fingerprint = snap.username + "@" + snap.host;
        if (fingerprint.equals(mRegisteredFingerprint) && mEngine.isStarted()
                && mEngine.getAccId() >= 0) {
            android.util.Log.i(TAG, "registerCurrentAccount: same account already"
                    + " registered (" + fingerprint + "), skip");
            return 0;
        }
        /* 防重入：另一路径正在注册中，本次跳过 */
        if (!mRegisterInFlight.compareAndSet(false, true)) {
            android.util.Log.i(TAG, "registerCurrentAccount: registration in progress, skip");
            return -2;
        }
        try {
            return doRegister(snap);
        } finally {
            mRegisterInFlight.set(false);
        }
    }

    private int doRegister(AccountSnapshot snap) {
        int target = transportToEngine(snap.transport);
        if (!mEngine.isStarted()) {
            Context ctx = AndroidUtil.getApplicationContext();
            if (!mEngine.engineStart(ctx, this, target)) {
                android.util.Log.e(TAG, "engineStart failed (transport=" + snap.transport + ")");
                return -1;
            }
        } else if (mEngine.getTransport() != target) {
            android.util.Log.i(TAG, "transport change " + mEngine.getTransport()
                    + " -> " + target + ": rebuild engine then re-register");
            restartEngineAndRegister(target);
            return -2;
        }
        /* 换了账号（非同指纹）：先注销旧账号 */
        if (mRegisteredFingerprint != null && mEngine.isStarted()) {
            android.util.Log.i(TAG, "registerCurrentAccount: different account,"
                    + " unregister " + mRegisteredFingerprint);
            mEngine.accountUnregister();
            mRegisteredFingerprint = null;
        }
        int accId = mEngine.accountRegister(snap.host, snap.username, snap.password,
                snap.proxy != null ? snap.proxy : "", snap.authUser, snap.displayName,
                snap.expires);
        if (accId >= 0) {
            mRegisteredFingerprint = snap.username + "@" + snap.host;
            Listeners observer = mObserver;
            if (observer != null) {
                observer.dispatchRegistrationStateChanged(
                        snap.id != null ? snap.id : "0", RegistrationState.Registering);
            }
        }
        return accId;
    }

    /** transport 变更：销毁引擎 → 延迟重建 → 按快照重注册 */
    private void restartEngineAndRegister(final int targetTransport) {
        mEngine.engineShutdown();
        mMain.postDelayed(new Runnable() {
            @Override
            public void run() {
                Context ctx = AndroidUtil.getApplicationContext();
                if (!mEngine.engineStart(ctx, SdkBridge.this, targetTransport)) {
                    android.util.Log.e(TAG, "engine rebuild failed");
                    return;
                }
                AccountSnapshot snap = mAccount;
                if (snap != null && snap.username != null && snap.host != null) {
                    mEngine.accountRegister(snap.host, snap.username, snap.password,
                            snap.proxy != null ? snap.proxy : "", snap.authUser,
                            snap.displayName, snap.expires);
                }
            }
        }, ENGINE_RESTART_DELAY_MS);
    }

    /* ---------------- 持久化（冷启动自恢复） ---------------- */

    private SharedPreferences prefs(Context context) {
        Context ctx = context != null ? context : AndroidUtil.getApplicationContext();
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private void persistAccountSnapshot() {
        try {
            AccountSnapshot s = mAccount;
            /* 防御：残缺快照（password 空）不覆盖已持久化的密码，就地用
             * 旧值补全——modify 链基于不完整 AccountXml 的 saveAccount 不得
             * 弄丢凭证（FCM 冷唤醒重注册依赖完整快照） */
            if (s.password == null || s.password.isEmpty()) {
                String old = prefs(null).getString(KEY_PASSWORD, null);
                if (old != null && !old.isEmpty()) {
                    s.password = old;
                }
            }
            prefs(null).edit()
                    .putString(KEY_ACCOUNT_ID, s.id)
                    .putString(KEY_USERNAME, s.username)
                    .putString(KEY_PASSWORD, s.password)
                    .putString(KEY_HOST, s.host)
                    .putString(KEY_PROXY, s.proxy)
                    .putString(KEY_AUTHUSER, s.authUser)
                    .putString(KEY_DISPLAYNAME, s.displayName)
                    .putInt(KEY_EXPIRES, s.expires)
                    .putString(KEY_TRANSPORT, s.transport)
                    .putString(KEY_PUSH_REPORT_URL, s.pushTokenReporterUrl)
                    .putString(KEY_PUSH_REPORT_HEADERS, s.pushTokenReporterCustomHeaders)
                    .apply();
        } catch (Throwable t) {
            android.util.Log.w(TAG, "persist account failed: " + t);
        }
    }

    private void restoreAccountSnapshot(Context context) {
        try {
            SharedPreferences sp = prefs(context);
            if (!sp.contains(KEY_USERNAME) || !sp.contains(KEY_HOST)) {
                return;
            }
            AccountSnapshot snap = new AccountSnapshot();
            snap.id = sp.getString(KEY_ACCOUNT_ID, null);
            snap.username = sp.getString(KEY_USERNAME, null);
            snap.password = sp.getString(KEY_PASSWORD, null);
            snap.host = sp.getString(KEY_HOST, null);
            snap.proxy = sp.getString(KEY_PROXY, null);
            snap.authUser = sp.getString(KEY_AUTHUSER, null);
            snap.displayName = sp.getString(KEY_DISPLAYNAME, null);
            snap.expires = sp.getInt(KEY_EXPIRES, 0);
            snap.transport = sp.getString(KEY_TRANSPORT, "tcp");
            snap.pushTokenReporterUrl = sp.getString(KEY_PUSH_REPORT_URL, null);
            snap.pushTokenReporterCustomHeaders = sp.getString(KEY_PUSH_REPORT_HEADERS, null);
            if (snap.username != null && !snap.username.isEmpty()
                    && snap.host != null && !snap.host.isEmpty()) {
                mAccount = snap;
                android.util.Log.i(TAG, "account snapshot restored (user=" + snap.username
                        + ", transport=" + snap.transport + ")");
            }
        } catch (Throwable t) {
            android.util.Log.w(TAG, "restore account failed: " + t);
        }
    }

    public void clearAccount() {
        SipForegroundService.stop();
        mAccount = new AccountSnapshot();
        try {
            prefs(null).edit().clear().apply();
        } catch (Throwable ignored) {
        }
        if (mEngine.isStarted()) {
            mEngine.accountUnregister();
        }
    }

    public AccountSnapshot accountSnapshot() {
        return mAccount;
    }

    /* ------------------------------------------------------------------ */
    /* 推送唤醒 / respawn / shutdown                                        */
    /* ------------------------------------------------------------------ */

    /** 唤醒注册标识头撤除延迟：re-REGISTER 组包发出后再撤（服务器已按头配对） */
    private static final long PUSH_HINT_CLEAR_DELAY_MS = 3000;

    private static final String PUSH_HINT_HEADER = "P-hint";

    /** P-hint 撤除定时器（单一可取消：3s 窗口内多条推送重挂，避免旧定时器提前撤新头） */
    private Runnable mPushHintClear;

    /** FCM token 登记（Instance.Notifications.Push.setRegistrationId）：存储并即时尝试上报 */
    public void setPushToken(String token) {
        PushTokenReporter.onToken(token);
    }

    /**
     * 推送到达（Notifications.Push.handle）：确保引擎在册并 re-REGISTER。
     * 业务键双头（X-Nov-Push-Session/X-REQUEST-ID）由 App 经
     * includeNonStandardSipHeader 先行注入；此处补引擎协议头
     * P-hint: background——服务器据此识别"推送唤醒的后台注册"并把 pending
     * 呼入 INVITE 下发到这条注册（缺此头 INVITE 不下发），随 re-REGISTER
     * 组包后 3s 撤除。
     */
    public boolean wakeupByPush() {
        if (!mEngine.isStarted()) {
            int target = transportToEngine(mAccount.transport);
            Context ctx = AndroidUtil.getApplicationContext();
            if (!mEngine.engineStart(ctx, this, target)) {
                android.util.Log.w(TAG, "wakeup: engineStart failed");
                return false;
            }
        }
        if (mPushHintClear != null) {
            mMain.removeCallbacks(mPushHintClear);
        }
        mRegisterHeaders.put(PUSH_HINT_HEADER, "background");
        applyRegisterHeaders();
        mPushHintClear = new Runnable() {
            @Override
            public void run() {
                mRegisterHeaders.remove(PUSH_HINT_HEADER);
                applyRegisterHeaders();
                mPushHintClear = null;
            }
        };
        mMain.postDelayed(mPushHintClear, PUSH_HINT_CLEAR_DELAY_MS);
        if (mEngine.getAccId() >= 0) {
            return mEngine.accountReregister();
        }
        int rc = registerCurrentAccount();
        return rc >= 0;
    }

    /** 重启引擎（respawn）：重建后按快照重注册 */
    public void respawn() {
        final int target = transportToEngine(mAccount.transport);
        mEngine.engineShutdown();
        mMain.postDelayed(new Runnable() {
            @Override
            public void run() {
                Context ctx = AndroidUtil.getApplicationContext();
                if (mEngine.engineStart(ctx, SdkBridge.this, target)) {
                    AccountSnapshot snap = mAccount;
                    if (snap != null && snap.username != null && snap.host != null) {
                        mEngine.accountRegister(snap.host, snap.username, snap.password,
                                snap.proxy != null ? snap.proxy : "", snap.authUser,
                                snap.displayName, snap.expires);
                    }
                }
            }
        }, ENGINE_RESTART_DELAY_MS);
    }

    /** 关停引擎（TerminateTask.execute）：现存 Telecom 连接一并拆除
     *  （PhoneAccount 保留——进程级账户随进程由 Telecom 清理） */
    public void shutdown() {
        SipForegroundService.stop();
        stopStatsPolling();
        stopCustomRingtone();
        if (!mTelecomDisabled) {
            try {
                mPendingIncomingCall.set(null);
                mReportedCallIds.clear();
                teardownTelecomConnections(new DisconnectCause(DisconnectCause.LOCAL));
            } catch (Throwable t) {
                android.util.Log.w(TAG, "telecom teardown on shutdown failed: " + t);
            }
        }
        mEngine.engineShutdown();
    }

    /* ------------------------------------------------------------------ */
    /* REGISTER / INVITE 自定义头                                           */
    /* ------------------------------------------------------------------ */

    private final Map<String, String> mRegisterHeaders =
            new java.util.LinkedHashMap<String, String>();

    /** includeNonStandardSipHeader：REGISTER 头即时下发引擎（粘性直到排除）；
     *  INVITE 头记录（引擎呼出仅支持一次性头注入，requestId 走 callMake 参数） */
    public void includeNonStandardSipHeader(int accountIndex, String method,
                                            String what, String name, String value) {
        if (name == null || name.isEmpty()) {
            return;
        }
        String key = name.trim();
        if ("REGISTER".equalsIgnoreCase(method)) {
            mRegisterHeaders.put(key, value != null ? value : "");
            applyRegisterHeaders();
        } else {
            android.util.Log.d(TAG, "custom " + method + " header recorded: "
                    + key + "=" + value + " (engine: INVITE headers via call path)");
        }
    }

    public void excludeNonStandardSipHeader(int accountIndex, String method,
                                            String what, String name) {
        if (name == null || name.isEmpty()) {
            return;
        }
        if ("REGISTER".equalsIgnoreCase(method)) {
            mRegisterHeaders.remove(name.trim());
            applyRegisterHeaders();
        }
    }

    private void applyRegisterHeaders() {
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : mRegisterHeaders.entrySet()) {
            if (sb.length() > 0) {
                sb.append("\r\n");
            }
            sb.append(e.getKey()).append(": ").append(e.getValue());
        }
        mEngine.setRegisterHeaders(sb.length() > 0 ? sb.toString() : null);
    }

    /* ------------------------------------------------------------------ */
    /* 音频                                                                 */
    /* ------------------------------------------------------------------ */

    public void setMuted(boolean muted) {
        mMuted = muted;
        for (CallSession s : mEngine.snapshotCalls()) {
            if (!s.isTerminal() && s.callId >= 0) {
                mEngine.callMute(s.callId, muted);
            }
        }
    }

    public boolean isMuted() {
        if (mMuted) {
            return true;
        }
        for (CallSession s : mEngine.snapshotCalls()) {
            if (!s.isTerminal() && s.muteFlag) {
                return true;
            }
        }
        return false;
    }

    /** 路由切换（Instance.Audio.setCallAudioRoute）：引擎执行 + 事件分发 +
     *  Telecom 特权路由协同 */
    public boolean setAudioRoute(AudioRoute route) {
        if (route == null || route == AudioRoute.Unselected) {
            return false;
        }
        boolean ok = mEngine.audioSetRoute(route.name());
        Listeners observer = mObserver;
        if (observer != null) {
            observer.dispatchAudioRouteChanged(currentAudioRoute());
        }
        syncAudioRoute(route.name());
        return ok;
    }

    /**
     * 当前路由（App 查询契约）：系统侧事实优先——活跃连接的
     * CallAudioState 是 Telecom AudioRouteStateMachine 的切换结果（含
     * OEM 特权执行），以此为准 UI 不滞后；无连接/未接通窗口回退引擎视角。
     */
    public AudioRoute currentAudioRoute() {
        String system = currentSystemAudioRoute();
        if (system != null) {
            try {
                return AudioRoute.valueOf(system);
            } catch (IllegalArgumentException ignored) {
            }
        }
        try {
            AudioRouteHelper.RouteInfo info = mEngine.audioGetCurrent();
            if (info != null && info.type != null) {
                return AudioRoute.valueOf(info.type);
            }
        } catch (Throwable ignored) {
        }
        return AudioRoute.Receiver;
    }

    public AudioRoute[] availableAudioRoutes() {
        List<AudioRoute> list = new ArrayList<AudioRoute>();
        try {
            for (AudioRouteHelper.RouteInfo info : mEngine.audioGetAvailable()) {
                if (info != null && info.type != null) {
                    try {
                        list.add(AudioRoute.valueOf(info.type));
                    } catch (IllegalArgumentException ignored) {
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        if (list.isEmpty()) {
            list.add(AudioRoute.Receiver);
            list.add(AudioRoute.Speaker);
        }
        return list.toArray(new AudioRoute[0]);
    }

    /** 首个非终态会话（DTMF 等单目标操作） */
    public CallSession firstActiveSession() {
        for (CallSession s : mEngine.snapshotCalls()) {
            if (!s.isTerminal() && s.callId >= 0) {
                return s;
            }
        }
        return null;
    }

    /* ------------------------------------------------------------------ */
    /* 统计轮询（getStats 异步 → 同步快照缓存）                             */
    /* ------------------------------------------------------------------ */

    private Runnable mStatsPoller;

    public void ensureStatsPolling() {
        boolean hasConfirmed = false;
        for (CallSession s : mEngine.snapshotCalls()) {
            if (!s.isTerminal() && s.callId >= 0
                    && s.pjsuaState == SipWebrtcEngine.CALL_STATE_CONFIRMED) {
                hasConfirmed = true;
                break;
            }
        }
        if (!hasConfirmed) {
            return;
        }
        if (mStatsPoller != null) {
            return;
        }
        mStatsPoller = new Runnable() {
            @Override
            public void run() {
                mStatsPoller = null;
                boolean any = false;
                for (final CallSession s : mEngine.snapshotCalls()) {
                    if (s.isTerminal() || s.callId < 0
                            || s.pjsuaState != SipWebrtcEngine.CALL_STATE_CONFIRMED) {
                        continue;
                    }
                    any = true;
                    final long id = s.sessionId;
                    try {
                        mEngine.getCallQuality(s.callId, new SipWebrtcEngine.QualityCallback() {
                            @Override
                            public void onQuality(SipWebrtcEngine.CallQualityData data) {
                                if (data != null && data.valid) {
                                    mStats.put(id, data);
                                }
                            }
                        });
                    } catch (Throwable ignored) {
                    }
                }
                if (any) {
                    mMain.postDelayed(this, STATS_POLL_MS);
                }
            }
        };
        mMain.post(mStatsPoller);
    }

    private void stopStatsPolling() {
        Runnable poller = mStatsPoller;
        if (poller != null) {
            mMain.removeCallbacks(poller);
            mStatsPoller = null;
        }
    }

    /** CallStatistics 快照（无缓存数据返回 null——App 按无统计处理） */
    public cz.acrobits.libsoftphone.data.CallStatistics statisticsOf(CallSession s) {
        SipWebrtcEngine.CallQualityData d = mStats.get(s.sessionId);
        if (d == null) {
            return null;
        }
        cz.acrobits.libsoftphone.data.CallStatistics st =
                new cz.acrobits.libsoftphone.data.CallStatistics();
        st.clockRateInHertz = 48000;
        st.maxJitter = (int) Math.round(d.jitterMs * 48);
        st.jitterBufferPacketLossPercentage =
                d.lossPct >= 0 ? (int) Math.round(d.lossPct) : 0;
        st.meteredNetworkJitter = (long) (d.jitterMs * 1000);
        st.avgRoundTripTimeInMilliseconds =
                d.rttMs >= 0 ? (int) Math.round(d.rttMs) : 0;
        return st;
    }

    /** 出向编解码友好名（MediaStatus.audio.outgoingPayloadFriendlyName） */
    public String codecOf(CallSession s) {
        SipWebrtcEngine.CallQualityData d = mStats.get(s.sessionId);
        return d != null && d.codec != null ? d.codec : "";
    }

    /** 当前网络接口名（NetworkStatus） */
    public String networkInterfaceName() {
        try {
            android.net.ConnectivityManager cm = AndroidUtil.getApplicationContext()
                    .getSystemService(android.net.ConnectivityManager.class);
            android.net.NetworkInfo info = cm != null ? cm.getActiveNetworkInfo() : null;
            if (info == null || !info.isConnected()) {
                return "none";
            }
            switch (info.getType()) {
                case android.net.ConnectivityManager.TYPE_WIFI:
                    return "wifi";
                case android.net.ConnectivityManager.TYPE_VPN:
                    return "vpn";
                case android.net.ConnectivityManager.TYPE_ETHERNET:
                    return "ethernet";
                default:
                    return "cellular";
            }
        } catch (Throwable t) {
            return "none";
        }
    }

    /* ------------------------------------------------------------------ */
    /* 日志缓冲（Instance.Log）                                             */
    /* ------------------------------------------------------------------ */

    public synchronized void appendLog(String msg) {
        if (msg == null) {
            return;
        }
        mLogBuffer.append(msg).append('\n');
        if (mLogBuffer.length() > LOG_LIMIT) {
            mLogBuffer.delete(0, mLogBuffer.length() - LOG_LIMIT);
        }
        OutputStream sink = mLogSink;
        if (sink != null) {
            try {
                sink.write((msg + "\n").getBytes("UTF-8"));
                sink.flush();
            } catch (Throwable t) {
                mLogSink = null;
            }
        }
    }

    public synchronized String logBuffer() {
        return mLogBuffer.toString();
    }

    public synchronized void clearLogBuffer() {
        mLogBuffer.setLength(0);
    }

    public void setLogSink(OutputStream sink) {
        mLogSink = sink;
    }

    /* ------------------------------------------------------------------ */
    /* Telecom 桥接：pending 单槽 + 连接表 +                              */
    /* 终态拆除 + 特权路由协同 + 系统路由事实通知）                         */
    /* ------------------------------------------------------------------ */

    /**
     * Telecom 桥接初始化（幂等；Instance.init 与来电上报前惰性调用）。
     *
     * PhoneAccount 注册由 App 侧 NovoServices.configureConnectionService 经
     * TelecomUtil.registerCallingAccount 完成（幂等，CAPABILITY_SELF_MANAGED）；
     * 本方法解析已注册 handle 并校验 TelecomManager 可用性，环境异常时
     * disable：本进程内 Telecom 桥接整体静默降级，通话主链不受影响。
     */
    public void initTelecom(Context context) {
        if (mTelecomDisabled || mTelecomInitialized) {
            return;
        }
        try {
            Context app = context != null ? context.getApplicationContext()
                    : AndroidUtil.getApplicationContext();
            if (app == null) {
                /* 无上下文（极早期回调）：不置位也不 disable，留待下次 */
                return;
            }
            TelecomManager tm = app.getSystemService(TelecomManager.class);
            if (tm == null) {
                disableTelecom("TelecomManager 不可用");
                return;
            }
            PhoneAccountHandle handle = TelecomUtil.registeredHandle();
            if (handle == null) {
                /* App 侧尚未注册（初始化时序）：不 disable，来电上报时经
                 * registeredHandle() 复查（进程重启场景系统侧账户仍在） */
                android.util.Log.i(TAG, "initTelecom: phone account not registered yet");
                return;
            }
            mTelecomInitialized = true;
            android.util.Log.i(TAG, "initTelecom ok: " + handle);
        } catch (Throwable t) {
            disableTelecom("init failed: " + t);
        }
    }

    /** 去电上报 Telecom（BT 挂断/路由协同）。
     *  使用 addNewIncomingCall（与来电同机制）：placeCall 在 self-managed
     *  场景被系统静默拒绝（无回调），addNewIncomingCall 已验证可用，
     *  Connection 对象是 BT 交互的核心，方向标签不影响 BT 功能。 */
    private void reportOutgoingToTelecom(CallEvent event, String number) {
        if (mTelecomDisabled) {
            return;
        }
        try {
            initTelecom(null);
            PhoneAccountHandle handle = TelecomUtil.registeredHandle();
            if (handle == null) {
                return;
            }
            TelecomManager tm = AndroidUtil.getApplicationContext()
                    .getSystemService(TelecomManager.class);
            if (tm == null) {
                return;
            }
            long eventId = event.getEventId();
            if (mReportedCallIds.contains(eventId)) {
                return;
            }
            Bundle extras = new Bundle();
            extras.putLong(EXTRA_EVENT_ID, eventId);
            mPendingIncomingCall.set(event);
            tm.addNewIncomingCall(handle, extras);
            mReportedCallIds.add(eventId);
            android.util.Log.i(TAG, "outgoing call reported to Telecom via incoming (eventId="
                    + eventId + ")");
        } catch (Throwable t) {
            noteTelecomFailure(t);
        }
    }

    /**
     * 上报来电（onIncomingCall 触发，每事件一次）。
     *
     * API 28+ 先 isIncomingCallPermitted（唯一版本分支）：蜂窝通话中系统
     * 不允许新的 self-managed 来电，false 时跳过（App UI 照常）且不记
     * 幂等集合——这是瞬态 false 的自愈路径；pending 单槽原子武装，
     * 上报成功记幂等门（Telecom 绑定异步，防窗口期重复
     * addNewIncomingCall 产生系统侧孤儿连接）。失败不阻断应用内来电链路。
     */
    private void reportIncomingToTelecom(CallEvent event) {
        if (mTelecomDisabled) {
            return;
        }
        try {
            initTelecom(null);
            PhoneAccountHandle handle = TelecomUtil.registeredHandle();
            if (handle == null) {
                return;
            }
            TelecomManager tm = AndroidUtil.getApplicationContext()
                    .getSystemService(TelecomManager.class);
            if (tm == null) {
                return;
            }
            long eventId = event.getEventId();
            if (mReportedCallIds.contains(eventId)) {
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                    && !tm.isIncomingCallPermitted(handle)) {
                android.util.Log.i(TAG, "reportIncomingToTelecom eventId=" + eventId
                        + " permitted=false，跳过上报");
                return;
            }
            Bundle extras = new Bundle();
            extras.putLong(EXTRA_EVENT_ID, eventId);
            mPendingIncomingCall.set(event);
            tm.addNewIncomingCall(handle, extras);
            mReportedCallIds.add(eventId);
            mTelecomFailureStreak.set(0);
            android.util.Log.i(TAG, "incoming call reported to Telecom (eventId="
                    + eventId + ", permitted=true)");
        } catch (Throwable t) {
            mPendingIncomingCall.set(null);
            noteTelecomFailure(t);
        }
    }

    /**
     * extractWaitingCall（App 的 NovoConnectionService 反射消费口）：
     * 原子消费 pending 单槽 + extras 配对（防串线/双消费），槽空或不匹配
     * 返回 empty（系统侧安静失败，不抛异常）。
     */
    public Optional<CallEvent> extractWaitingCall(ConnectionRequest request) {
        if (mTelecomDisabled) {
            return Optional.empty();
        }
        try {
            CallEvent pending = mPendingIncomingCall.getAndSet(null);
            if (pending == null) {
                return Optional.empty();
            }
            long requestEventId = -1L;
            if (request != null && request.getExtras() != null) {
                requestEventId = request.getExtras().getLong(EXTRA_EVENT_ID, -1L);
            }
            /* 配对策略：extras 透传时严格匹配（防串线）；部分 OEM 过滤
             * 上报 extras（request 无该键）——此时单槽直接消费
             * （self-managed 场景 addNewIncomingCall 只来自本进程） */
            if (requestEventId != -1L && requestEventId != pending.getEventId()) {
                android.util.Log.w(TAG, "extractWaitingCall 槽不匹配（pending="
                        + pending.getEventId() + " request=" + requestEventId + "）");
                return Optional.empty();
            }
            CallSession s = findSession(pending.getEventId());
            if (s == null || s.isTerminal() || !s.isIncoming() || s.answerRequested) {
                return Optional.empty();
            }
            mTelecomFailureStreak.set(0);
            return Optional.of(pending);
        } catch (Throwable t) {
            noteTelecomFailure(t);
            return Optional.empty();
        }
    }

    /**
     * self-managed 并发连接是否达上限（App 的 NovoConnectionService 反射
     * 调用）。先清孤儿再计数；上限对齐系统侧容量——旧实现"同时一路"
     * 是第二通来电（通话中呼入）蓝牙不响铃、无法接听的根因。
     */
    public boolean hasMaximumSelfManagedConnections() {
        pruneDestroyedTelecomConnections();
        int live = 0;
        for (Connection c : mTelecomConnections.values()) {
            if (c != null && c.getState() != Connection.STATE_DISCONNECTED) {
                live++;
            }
        }
        return live >= MAX_SELF_MANAGED_CONNECTIONS;
    }

    /** ConnectionImpl 构造时登记（eventId → Connection；Telecom binder 线程） */
    public void registerTelecomConnection(long eventId, Connection connection) {
        if (eventId > 0 && connection != null) {
            mTelecomConnections.put(eventId, connection);
        }
    }

    /**
     * 状态映射（非终态；幂等——ConnectionImpl 侧状态比较跳过）。
     * hold 仅映射本地 holdFlag（remoteHold 是对端行为，系统侧不体现）。
     * Established 且非 hold：对齐 ACTIVE 后协同路由——引擎路由决策同步
     * 到 Telecom（OEM 特权路由压制场景由 Telecom 侧实际执行；幂等短路）。
     */
    private void syncConnectionState(CallSession session, Call.State state) {
        if (mTelecomDisabled || session == null) {
            return;
        }
        Connection connection = mTelecomConnections.get(session.sessionId);
        if (connection == null) {
            return;
        }
        try {
            cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                    .applyCallState(connection, state, session.holdFlag);
            if (!session.holdFlag
                    && (CallSession.STATE_ESTABLISHED.equals(session.callStateView)
                        || CallSession.STATE_INCOMING_ANSWERED.equals(session.callStateView))) {
                String route = engineRouteType();
                if (route != null) {
                    syncAudioRoute(route);
                }
            }
            mTelecomFailureStreak.set(0);
        } catch (Throwable t) {
            noteTelecomFailure(t);
        }
    }

    /**
     * 终态拆除：即时 setDisconnected（系统 UI 即刻收尾）→ 延迟 destroy +
     * 移表（1.5s 收尾）。会话终态事件在 Registry 滞留窗口内会多次到达，
     * 已断开的连接幂等跳过（首次拆除已排定 destroy）。终态不拆除会留下
     * 幽灵连接，阻塞后续通话的 Telecom 上报。
     */
    private void teardownConnection(final long eventId, CallSession session, Call.State state) {
        if (mTelecomDisabled) {
            return;
        }
        mReportedCallIds.remove(eventId);
        final Connection connection = mTelecomConnections.get(eventId);
        if (connection == null) {
            return;
        }
        try {
            if (connection.getState() == Connection.STATE_DISCONNECTED) {
                /* 首次拆除已排定 destroy（终态事件重复到达），幂等跳过 */
                return;
            }
            connection.setDisconnected(causeFor(session, state));
        } catch (Throwable t) {
            android.util.Log.w(TAG, "teardownConnection disconnect failed: " + t);
        }
        mMain.postDelayed(new Runnable() {
            @Override
            public void run() {
                Connection c = mTelecomConnections.remove(eventId);
                if (c != null) {
                    try {
                        c.destroy();
                    } catch (Throwable ignored) {
                    }
                }
            }
        }, TELECOM_TEARDOWN_DELAY_MS);
    }

    /** 逐连接 disconnect + destroy 并清表（shutdown / disable 路径） */
    private void teardownTelecomConnections(DisconnectCause cause) {
        Iterator<Map.Entry<Long, Connection>> it = mTelecomConnections.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<Long, Connection> entry = it.next();
            it.remove();
            try {
                entry.getValue().setDisconnected(cause);
                entry.getValue().destroy();
            } catch (Throwable t) {
                android.util.Log.w(TAG, "teardown connection failed: " + t);
            }
        }
    }

    /**
     * 孤儿连接清理：连接表与引擎终态可能不同步（如 ConnectionService 被
     * 杀后系统侧拆除），每次事件先清理已 DISCONNECTED 条目
     */
    private void pruneDestroyedTelecomConnections() {
        if (mTelecomConnections.isEmpty()) {
            return;
        }
        Iterator<Map.Entry<Long, Connection>> it = mTelecomConnections.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<Long, Connection> entry = it.next();
            Connection c = entry.getValue();
            if (c == null || c.getState() == Connection.STATE_DISCONNECTED) {
                it.remove();
            }
        }
    }

    /**
     * DisconnectCause 映射：按会话视图优先（Terminated 按方向裁决：呼出
     * LOCAL / 呼入 REMOTE——BT 挂断来电表现为 REMOTE 是预期语义）；无
     * 会话回退按 App State 映射。
     */
    private static DisconnectCause causeFor(CallSession session, Call.State state) {
        if (session != null) {
            String v = session.callStateView;
            if (CallSession.STATE_INCOMING_REJECTED.equals(v)) {
                return new DisconnectCause(DisconnectCause.REJECTED);
            }
            if (CallSession.STATE_INCOMING_MISSED.equals(v)) {
                return new DisconnectCause(DisconnectCause.MISSED);
            }
            if (CallSession.STATE_BUSY.equals(v)) {
                return new DisconnectCause(DisconnectCause.BUSY);
            }
            if (CallSession.STATE_ERROR.equals(v)
                    || CallSession.STATE_UNAUTHORIZED.equals(v)) {
                return new DisconnectCause(DisconnectCause.ERROR);
            }
            if (CallSession.STATE_TERMINATED.equals(v)) {
                return new DisconnectCause(session.direction == CallSession.DIRECTION_OUT
                        ? DisconnectCause.LOCAL : DisconnectCause.REMOTE);
            }
        }
        if (state != null) {
            switch (state) {
                case IncomingRejected:
                    return new DisconnectCause(DisconnectCause.REJECTED);
                case IncomingMissed:
                    return new DisconnectCause(DisconnectCause.MISSED);
                case IncomingIgnored:
                    return new DisconnectCause(DisconnectCause.CANCELED);
                default:
                    break;
            }
        }
        return new DisconnectCause(DisconnectCause.REMOTE);
    }

    /**
     * App 路由意图同步到 Telecom（对活跃连接调 Connection.setAudioRoute）。
     *
     * OEM（三星实测）对存在 Connection 的通话以特权身份管理通信设备，
     * App 侧 setCommunicationDevice 被压制（SCO 活跃时切不出扬声器、
     * hold/resume 后被重设回听筒）；Connection.setAudioRoute 驱动
     * Telecom 自身的 AudioRouteStateMachine 完整切换（含断 SCO），特权
     * 执行；AOSP 语义下与 App 直设等价（重复设置幂等）。无活跃连接时
     * no-op（引擎直设路径自身生效）。失败仅日志（不进熔断：路由操作
     * 高频，熔断会连坐来电链路）。
     */
    public void syncAudioRoute(String route) {
        if (mTelecomDisabled || route == null) {
            return;
        }
        try {
            Connection connection = activeTelecomConnection();
            if (connection == null) {
                return;
            }
            int target = telecomRouteOf(route);
            /* 幂等短路：系统侧路由已是目标则不重复 binder 调用 */
            CallAudioState current = connection.getCallAudioState();
            if (current != null && current.getRoute() == target) {
                return;
            }
            connection.setAudioRoute(target);
            android.util.Log.i(TAG, "syncAudioRoute " + route + " -> telecom route=" + target);
        } catch (Throwable t) {
            android.util.Log.w(TAG, "syncAudioRoute 失败: " + t);
        }
    }

    /**
     * 系统侧当前路由事实（字符串协议；无连接/查询失败返回 null，调用方
     * 回退引擎视角）。仅认已接通（ACTIVE/HOLDING）连接：振铃/拨号期
     * Connection 的 callAudioState 是系统初始值，与引擎实际路由不符。
     */
    public String currentSystemAudioRoute() {
        if (mTelecomDisabled) {
            return null;
        }
        try {
            Connection connection = activeTelecomConnection();
            if (connection == null) {
                return null;
            }
            int st = connection.getState();
            if (st != Connection.STATE_ACTIVE && st != Connection.STATE_HOLDING) {
                return null;
            }
            CallAudioState state = connection.getCallAudioState();
            if (state == null) {
                return null;
            }
            return stringRouteOf(state.getRoute());
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * 系统路由事实变化通知入口（ConnectionImpl.onCallAudioStateChanged
     * 转发；Telecom 线程）。CallAudioState 变化即 AudioRouteStateMachine
     * 切换完成时刻（含断 SCO 的蓝牙切换），据此驱动 UI 刷新（观察者
     * 通道 + App 注册的回调通道），取代固定延时轮询。
     */
    public void onSystemAudioRouteChanged(CallAudioState state) {
        if (state == null) {
            return;
        }
        String route = stringRouteOf(state.getRoute());
        if (route == null) {
            return;
        }
        Listeners observer = mObserver;
        if (observer != null) {
            try {
                observer.dispatchAudioRouteChanged(AudioRoute.valueOf(route));
            } catch (Throwable ignored) {
            }
        }
    }


    /**
     * 当前应承接路由协同的连接：STATE_ACTIVE 优先（多路并发时路由属于
     * 活跃通话，无序遍历不加筛选会错选保持中的连接），退而取任一非断开
     * 态（单通话常态）
     */
    private Connection activeTelecomConnection() {
        Connection fallback = null;
        for (Connection c : mTelecomConnections.values()) {
            if (c == null || c.getState() == Connection.STATE_DISCONNECTED) {
                continue;
            }
            if (c.getState() == Connection.STATE_ACTIVE) {
                return c;
            }
            if (fallback == null) {
                fallback = c;
            }
        }
        return fallback;
    }

    /**
     * 是否存在蜂窝（managed）通话。
     *
     * 用于 Connection.onDisconnect 的三星仲裁策略防御：蜂窝来电期间系统
     * 无视 CAPABILITY_SUPPORT_HOLD 先 markCallAsDisconnected 再回调
     * onDisconnect 终结 VoIP 通话。isInManagedCall 只统计 managed call
     * （蜂窝），self-managed（本 App）不计入，天然区分。API 31+；
     * 低版本不可判定返回 false（防御不触发，行为退化为正常挂断）。
     */
    public boolean isManagedCellularCallActive() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return false;
        }
        try {
            TelecomManager tm = AndroidUtil.getApplicationContext()
                    .getSystemService(TelecomManager.class);
            return tm != null && tm.isInManagedCall();
        } catch (Throwable t) {
            android.util.Log.w(TAG, "isInManagedCall 查询失败: " + t);
            return false;
        }
    }

    /**
     * 前台化 App：蓝牙耳机接听且 App 不在前台时调用。
     * 冷启动场景（FCM 拉起 + 耳机接听）——①通话 UI 不在前台；②Android 15
     * 后台麦克风采集受限（while-in-use），对端听不到我方。此处启动
     * MainActivity 拉回前台（前台后 RN hydrate 自动导航通话页
     * 已知边界：startActivity 无返回值，Android 10+ 的 BAL 拦截为静默
     * 丢弃——SYSTEM_ALERT_WINDOW 未授予时冷启动场景可能前台化失败，
     * 通话功能不受影响，回前台即恢复）。*/
    public void bringAppToFront() {
        Context ctx = AndroidUtil.getApplicationContext();
        if (ctx == null) {
            return;
        }
        try {
            android.content.Intent intent = ctx.getPackageManager()
                    .getLaunchIntentForPackage(ctx.getPackageName());
            if (intent != null) {
                intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                        | android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP);
                ctx.startActivity(intent);
                android.util.Log.i(TAG, "耳机接听：已发起前台化");
            }
        } catch (Throwable t) {
            android.util.Log.w(TAG, "前台化失败: " + t);
        }
    }

    /** 字符串协议路由 → CallAudioState 路由常量（BluetoothA2DP 归蓝牙） */
    private static int telecomRouteOf(String route) {
        if (AudioRouteHelper.ROUTE_SPEAKER.equals(route)) {
            return CallAudioState.ROUTE_SPEAKER;
        }
        if (AudioRouteHelper.ROUTE_BLUETOOTH_SCO.equals(route)
                || AudioRoute.BluetoothA2DP.name().equals(route)) {
            return CallAudioState.ROUTE_BLUETOOTH;
        }
        if (AudioRouteHelper.ROUTE_HEADSET.equals(route)) {
            return CallAudioState.ROUTE_WIRED_HEADSET;
        }
        return CallAudioState.ROUTE_EARPIECE;
    }

    /** CallAudioState 路由常量 → 字符串协议路由（未知返回 null） */
    private static String stringRouteOf(int route) {
        switch (route) {
            case CallAudioState.ROUTE_SPEAKER:
                return AudioRouteHelper.ROUTE_SPEAKER;
            case CallAudioState.ROUTE_BLUETOOTH:
                return AudioRouteHelper.ROUTE_BLUETOOTH_SCO;
            case CallAudioState.ROUTE_WIRED_HEADSET:
                return AudioRouteHelper.ROUTE_HEADSET;
            case CallAudioState.ROUTE_EARPIECE:
                return AudioRouteHelper.ROUTE_RECEIVER;
            default:
                return null;
        }
    }

    /** 引擎当前路由（字符串协议；查询失败 null） */
    private String engineRouteType() {
        try {
            AudioRouteHelper.RouteInfo info = mEngine.audioGetCurrent();
            if (info != null) {
                return info.type;
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    /** ConnectionCompat.audioRouting(c).setAudioRoutingCallback(service) 落点 */
    public void bindAudioRoutingService(Connection connection,
                                        cz.acrobits.libsoftphone.telecom.ConnectionService service) {
        mAudioRoutingBoundConnection = connection;
        mAudioRoutingService = service;
    }

    /**
     * 运行期连续异常计数：达到阈值熔断 disable（disable 前先拆现存连接
     * ——此后不再有状态映射，残留连接会在系统侧显示幽灵通话）
     */
    private void noteTelecomFailure(Throwable t) {
        int streak = mTelecomFailureStreak.incrementAndGet();
        android.util.Log.w(TAG, "telecom degraded(第 " + streak + " 次): " + t);
        if (streak >= TELECOM_FAILURE_TRIP) {
            disableTelecom("运行期连续失败 " + streak + " 次（熔断）");
        }
    }

    /** 置位降级并拆除现存连接（置位点：init 失败 / 运行期熔断） */
    private void disableTelecom(String reason) {
        mTelecomDisabled = true;
        android.util.Log.w(TAG, "telecom disabled: " + reason);
        try {
            mPendingIncomingCall.set(null);
            mReportedCallIds.clear();
            teardownTelecomConnections(new DisconnectCause(DisconnectCause.ERROR));
        } catch (Throwable t) {
            android.util.Log.w(TAG, "telecom teardown on disable failed: " + t);
        }
    }

    /** 默认 onSilence（App 子类覆盖后不触达）：停铃声保来电 */
    public void ignoreIncoming(CallEvent event) {
        stopCustomRingtone();
        RingtoneHelper.stopRingtone();
    }

    /* ------------------------------------------------------------------ */
    /* 会议组（单腿组模型：每会话一组）                                     */
    /* ------------------------------------------------------------------ */

    public String groupOf(CallSession s) {
        if (s.groupId != null && !s.groupId.isEmpty()) {
            return s.groupId;
        }
        return String.valueOf(s.sessionId);
    }

    /** 全部组 id（插入序去重；含终态滞留会话——App 据此展示终态后关闭） */
    public List<String> allGroups() {
        List<String> groups = new ArrayList<String>();
        for (CallSession s : mEngine.snapshotCalls()) {
            String g = groupOf(s);
            if (!groups.contains(g)) {
                groups.add(g);
            }
        }
        return groups;
    }

    /** 组内会话 */
    public List<CallSession> sessionsOfGroup(String groupId) {
        List<CallSession> list = new ArrayList<CallSession>();
        if (groupId == null) {
            return list;
        }
        for (CallSession s : mEngine.snapshotCalls()) {
            if (groupId.equals(groupOf(s))) {
                list.add(s);
            }
        }
        return list;
    }

    /* 活跃组追踪（Conferences.setActive / getActive） */
    private volatile String mActiveGroupId;

    public String getActiveGroupId() {
        String g = mActiveGroupId;
        if (g == null) {
            return null;
        }
        for (CallSession s : sessionsOfGroup(g)) {
            if (!s.isTerminal()) {
                return g;
            }
        }
        return null;
    }

    public void setActiveGroupId(String groupId) {
        mActiveGroupId = groupId;
    }

    /** 消息事件占位（App OnNewEvent 的 MessageEvent 分支仅 Toast） */
    public boolean postMessageEvent(MessageEvent event) {
        android.util.Log.i(TAG, "message event dropped (no messaging engine): "
                + (event != null ? event.body : null));
        return true;
    }
}
