package cz.acrobits.libsoftphone;

import android.app.Notification;
import android.app.NotificationManager;
import android.content.Context;

import com.yeastar.sipcore.CallSession;
import com.yeastar.sipcore.SdkBridge;

import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import cz.acrobits.ali.AndroidUtil;
import cz.acrobits.libsoftphone.account.AccountXml;
import cz.acrobits.libsoftphone.data.AudioRoute;
import cz.acrobits.libsoftphone.data.Call;
import cz.acrobits.libsoftphone.data.CallStatistics;
import cz.acrobits.libsoftphone.data.MediaStatus;
import cz.acrobits.libsoftphone.data.NetworkStatus;
import cz.acrobits.libsoftphone.data.SipHeader;
import cz.acrobits.libsoftphone.event.CallEvent;
import cz.acrobits.libsoftphone.event.Event;
import cz.acrobits.libsoftphone.event.MessageEvent;
import cz.acrobits.libsoftphone.support.Listeners;

/**
 * Acrobits libSoftPhone SDK 兼容门面入口（Instance）。
 *
 * 包名/类名/方法签名与 Acrobits SDK 完全一致——宿主 App 零改动编译；
 * 全部通话/音频/注册/通知/事件操作转发 :sip-core SipWebrtcEngine
 * （经 {@link SdkBridge}）。
 *
 * 结构说明（对齐真实 SDK 的可编译性约束）：Calls/Audio/... 均为嵌套类 +
 * 静态方法形态。不能用"静态字段持模块实例"——App 的 Java 代码存在
 * {@code Instance.Events.PostResult.SUCCESS} 嵌套类型路径引用，经实例
 * 字段引用嵌套类型在 Java 中非法（JLS 6.5.2 字段优先），必须经嵌套类
 * 静态路径解析。
 *
 * 身份契约：CallEvent.getEventId() == CallSession.sessionId。
 */
public final class Instance {

    private static final String TAG = "Acrobits.Instance";

    /** 偏好（init 后非 null；类型为基类——App 访问的成员均在基类） */
    public static Preferences preferences;

    private Instance() {
    }

    /* ---------------- 生命周期 ---------------- */

    /** 库加载（.so 由引擎启动链懒加载，此处仅确保 Context 就位） */
    public static void loadLibrary(Context context) {
        AndroidUtil.setContext(context);
    }

    /**
     * SDK 初始化：偏好实例化（宿主 preferencesClass 反射构造）+
     * Activity 追踪装配 + 冷启动账号快照恢复（引擎启动延后到账号注册）。
     */
    public static void init(Context context, cz.acrobits.ali.Xml provisioning,
                            Class<?> preferencesClass) {
        AndroidUtil.setContext(context);
        SdkBridge.get().init(context);
        try {
            preferences = (Preferences) preferencesClass.getDeclaredConstructor().newInstance();
        } catch (Throwable t) {
            android.util.Log.w(TAG, "preferences class failed: " + t + " -> base");
            preferences = new Preferences();
        }
    }

    /** 观察者（Listeners 聚合；引擎回调经此分发） */
    public static void setObserver(Listeners listeners) {
        SdkBridge.get().setObserver(listeners);
    }

    /* ================================================================== */
    /* Calls                                                              */
    /* ================================================================== */

    /** 通话模块 */
    public static final class Calls {

        /** 会议组子模块（本引擎单腿组模型：每会话一组，groupId=String(id)） */
        public static final class Conferences {

            /** 通话所属组 id */
            public static String get(CallEvent event) {
                CallSession s = session(event);
                return s != null ? bridge().groupOf(s) : null;
            }

            /** 组内通话（不存在的组返回空数组） */
            public static CallEvent[] getCalls(String groupId) {
                List<CallEvent> list = new ArrayList<CallEvent>();
                for (CallSession s : bridge().sessionsOfGroup(groupId)) {
                    list.add(bridge().wrapEvent(s));
                }
                return list.toArray(new CallEvent[0]);
            }

            /** 全部组 id（含终态滞留；App 遍历驱动刷新/挂断/关闭） */
            public static String[] list() {
                return bridge().allGroups().toArray(new String[0]);
            }

            /** 当前活跃组（无返回 null） */
            public static String getActive() {
                return bridge().getActiveGroupId();
            }

            /** 置活跃组（null = 取消活跃） */
            public static void setActive(String groupId) {
                bridge().setActiveGroupId(groupId);
            }

            /** 置活跃组（单腿通话解除保持时恢复活跃） */
            public static void setActive(CallEvent event) {
                CallSession s = session(event);
                if (s != null) {
                    bridge().setActiveGroupId(bridge().groupOf(s));
                }
            }

            /** 组内通话数（按通话） */
            public static int getSize(CallEvent event) {
                String group = get(event);
                return group != null ? getSize(group) : 0;
            }

            /** 组内通话数（按组） */
            public static int getSize(String groupId) {
                return bridge().sessionsOfGroup(groupId).size();
            }

            /** 组数 */
            public static int count() {
                return bridge().allGroups().size();
            }

            /** 生成新组 id（组能力仅 id 语义：本引擎无服务端会议桥） */
            public static String generate(String name) {
                return name + "-" + CONF_SEQ.incrementAndGet();
            }

            /** 移入组（本引擎单腿组，no-op 记录） */
            public static void move(CallEvent event, String groupId) {
                android.util.Log.d(TAG, "Conferences.move -> " + groupId
                        + " (single-leg groups, no-op)");
            }

            /** 从组分离（本引擎单腿组，no-op 记录） */
            public static void split(CallEvent event, boolean close) {
                android.util.Log.d(TAG, "Conferences.split close=" + close
                        + " (single-leg groups, no-op)");
            }

            /** 盲转（REFER）：把 event 通话转给 newCall 的对端号码 */
            public static void transfer(CallEvent event, CallEvent newCall) {
                CallSession s = session(event);
                if (s == null || s.callId < 0 || newCall == null
                        || newCall.remoteUser == null || newCall.remoteUser.genericUri == null) {
                    return;
                }
                bridge().engine().callXfer(s.callId, newCall.remoteUser.genericUri);
            }

            /** 咨询转（REFER + Replaces）：两路活跃通话对拼，成功后服务器接管 */
            public static void attendedTransfer(CallEvent from, CallEvent to) {
                CallSession a = session(from);
                CallSession b = session(to);
                if (a == null || b == null || a.callId < 0 || b.callId < 0) {
                    return;
                }
                bridge().engine().callXferAttended(a.callId, b.callId);
            }
        }

        private static SdkBridge bridge() {
            return SdkBridge.get();
        }

        private static CallSession session(CallEvent event) {
            return bridge().findSession(event != null ? event.getEventId() : 0);
        }

        /** 通话状态（会话不存在返回 Error——终态，App 据此收口） */
        public static Call.State getState(CallEvent event) {
            CallSession s = session(event);
            return s != null ? bridge().mapState(s) : Call.State.Error;
        }

        /** 接听来电（DesiredMedia 仅支持 voiceOnly 形态） */
        public static void answerIncoming(CallEvent event, Call.DesiredMedia media) {
            CallSession s = session(event);
            if (s == null || s.callId < 0) {
                return;
            }
            bridge().engine().callAnswer(s.callId);
        }

        /** 挂断/关闭（振铃期来电转拒接语义，对齐 Acrobits close） */
        public static void close(CallEvent event) {
            CallSession s = session(event);
            if (s == null || s.callId < 0) {
                return;
            }
            /* 已终态静默跳过：JS 层挂断可能多次派发（按钮点击 + 状态监听
             * 重试），已终态的通话再 callHangup 引擎返回 false → App 层
             * hangUpUseCase 视为异常 → 弹"通话异常"对话框 */
            if (s.isTerminal()) {
                return;
            }
            if (s.isIncoming() && !s.answerRequested) {
                bridge().engine().callReject(s.callId);
            } else {
                bridge().engine().callHangup(s.callId);
            }
        }

        /** 拒接来电（486） */
        public static void rejectIncomingHere(CallEvent event, Call.RejectReason reason) {
            CallSession s = session(event);
            if (s == null || s.callId < 0) {
                return;
            }
            bridge().engine().callReject(s.callId);
        }

        /** 保持状态（未保持侧为 null） */
        public static Call.HoldStates isHeld(CallEvent event) {
            CallSession s = session(event);
            if (s == null) {
                return new Call.HoldStates(null, null);
            }
            return new Call.HoldStates(
                    s.holdFlag ? Call.HoldState.Held : null,
                    s.remoteHoldFlag ? Call.HoldState.Held : null);
        }

        /** 保持/恢复（本地 track 静音 + re-INVITE 方向切换） */
        public static void setHeld(CallEvent event, boolean held) {
            CallSession s = session(event);
            if (s == null || s.callId < 0) {
                return;
            }
            bridge().engine().callHold(s.callId, held);
        }

        /** 非终态通话列表 */
        public static List<CallEvent> getActive() {
            List<CallEvent> list = new ArrayList<CallEvent>();
            for (CallSession s : bridge().engine().snapshotCalls()) {
                if (!s.isTerminal()) {
                    list.add(bridge().wrapEvent(s));
                }
            }
            return list;
        }

        /** 通话统计（WebRTC getStats 1s 轮询缓存；无数据返回 null） */
        public static CallStatistics getStatistics(CallEvent event) {
            CallSession s = session(event);
            return s != null ? bridge().statisticsOf(s) : null;
        }

        /** 媒体状态（出向编解码名） */
        public static MediaStatus getMediaStatus(CallEvent event) {
            CallSession s = session(event);
            if (s == null) {
                return null;
            }
            MediaStatus status = new MediaStatus();
            status.audio.outgoingPayloadFriendlyName = bridge().codecOf(s);
            return status;
        }

        /** 网络状态（当前网络接口名） */
        public static NetworkStatus getNetworkStatus(CallEvent event) {
            NetworkStatus status = new NetworkStatus();
            status.networkInterfaceName = bridge().networkInterfaceName();
            return status;
        }

        /**
         * 查询收到的 SIP 头（来电 INVITE 头缓存；接通后对话框切换不可再读，
         * App 在 IncomingRinging 时把头值写入 transients 供接通后读取）。
         */
        public static SipHeader findSipHeader(CallEvent event, String name) {
            CallSession s = session(event);
            if (s == null || s.callId < 0 || name == null) {
                return null;
            }
            String value = bridge().engine().callGetHeader(s.callId, name);
            return value != null ? new SipHeader(name, value) : null;
        }
    }

    private static final AtomicLong CONF_SEQ = new AtomicLong();

    /* ================================================================== */
    /* Audio                                                              */
    /* ================================================================== */

    /** 音频模块 */
    public static final class Audio {

        /** 全局静音（应用到全部活跃通话；新通话拨出时镜像应用） */
        public static void setMuted(boolean muted) {
            SdkBridge.get().setMuted(muted);
        }

        public static boolean isMuted() {
            return SdkBridge.get().isMuted();
        }

        /** DTMF（RTP telephone-event，200ms/100ms；App 契约按下发音） */
        public static void dtmfOn(byte digit) {
            CallSession s = SdkBridge.get().firstActiveSession();
            if (s != null) {
                SdkBridge.get().engine().callDtmf(s.callId, (char) digit);
            }
        }

        /** DTMF 停止（RTP DTMF 无持续发音语义，no-op） */
        public static void dtmfOff() {
        }

        /** 切换通话路由（Receiver/Speaker/BluetoothSCO/Headset） */
        public static void setCallAudioRoute(AudioRoute route) {
            SdkBridge.get().setAudioRoute(route);
        }

        public static AudioRoute getCallAudioRoute() {
            return SdkBridge.get().currentAudioRoute();
        }

        public static AudioRoute[] getAvailableCallAudioRoutes() {
            return SdkBridge.get().availableAudioRoutes();
        }
    }

    /* ================================================================== */
    /* Registration                                                       */
    /* ================================================================== */

    /** 注册模块 */
    public static final class Registration {

        private static SdkBridge bridge() {
            return SdkBridge.get();
        }

        /** 保存并注册账号（transport 变更触发引擎重建；禁用账号 = 注销） */
        public static void saveAccount(AccountXml account) {
            if (account != null && !account.isEnabled()) {
                /* 注销路径（App：clone.setEnabled(false) → saveAccount → updateAll） */
                bridge().clearAccount();
                return;
            }
            int rc = bridge().saveAccount(account);
            android.util.Log.i(TAG, "saveAccount -> register rc=" + rc);
        }

        /** 删除账号（注销 + 清持久化） */
        public static void deleteAccount(String accountId) {
            bridge().clearAccount();
        }

        /** 账号数（单账号引擎：0 或 1） */
        public static int getAccountCount() {
            SdkBridge.AccountSnapshot snap = bridge().accountSnapshot();
            return snap != null && snap.username != null && !snap.username.isEmpty() ? 1 : 0;
        }

        /**
         * 按下标取账号（仅 0 有效；构造完整 AccountXml——含 password/expires/
         * transport 等全部注册字段）。
         *
         * 字段必须完整：App 的 modifyAccount 是"getAccount → clone → merge →
         * saveAccount"模式，此处缺字段会被 clone 原样带过、saveAccount 覆盖
         * 掉账号快照——password 丢失后 FCM 冷唤醒（restore 快照重注册）在
         * JNI 层静默失败（copy_jstring 对 NULL 返回 -1），服务器不下发
         * INVITE，推送唤醒来电无声失效。
         */
        public static AccountXml getAccount(int index) {
            if (index != 0 || getAccountCount() == 0) {
                return null;
            }
            SdkBridge.AccountSnapshot snap = bridge().accountSnapshot();
            cz.acrobits.ali.Xml xml = new cz.acrobits.ali.Xml(
                    cz.acrobits.libsoftphone.data.Account.ACCOUNT);
            xml.setAttribute(cz.acrobits.libsoftphone.data.Account.Attributes.ID,
                    snap.id != null ? snap.id : "");
            xml.setChildValue("username", snap.username != null ? snap.username : "");
            xml.setChildValue("host", snap.host != null ? snap.host : "");
            /* 注册全字段（空值不写——保持缺省字段不落树的形态，也防
             * expires=0 之类脏值经 modify 链固化） */
            if (snap.password != null && !snap.password.isEmpty()) {
                xml.setChildValue("password", snap.password);
            }
            if (snap.proxy != null && !snap.proxy.isEmpty()) {
                xml.setChildValue("outboundProxy_host", snap.proxy);
            }
            if (snap.authUser != null && !snap.authUser.isEmpty()) {
                xml.setChildValue("authUsername", snap.authUser);
            }
            if (snap.displayName != null && !snap.displayName.isEmpty()) {
                xml.setChildValue("displayName", snap.displayName);
            }
            if (snap.expires > 0) {
                xml.setChildValue("expires", String.valueOf(snap.expires));
            }
            if (snap.transport != null && !snap.transport.isEmpty()) {
                xml.setChildValue("transport", snap.transport);
            }
            if (snap.pushTokenReporterUrl != null && !snap.pushTokenReporterUrl.isEmpty()) {
                xml.setChildValue("pushTokenReporterUrl", snap.pushTokenReporterUrl);
            }
            if (snap.pushTokenReporterCustomHeaders != null
                    && !snap.pushTokenReporterCustomHeaders.isEmpty()) {
                xml.setChildValue("pushTokenReporterCustomHeaders",
                        snap.pushTokenReporterCustomHeaders);
            }
            return new AccountXml(xml,
                    cz.acrobits.libsoftphone.mergeable.MergeableNodeAttributes.gui());
        }

        /** 刷新注册（重发 REGISTER；配置变更后的 apply 语义） */
        public static void updateAll() {
            if (bridge().engine().getAccId() >= 0) {
                bridge().engine().accountReregister();
            } else {
                bridge().registerCurrentAccount();
            }
        }

        /** 默认账号 id（未注册返回 null） */
        public static String getDefaultAccountId() {
            SdkBridge.AccountSnapshot snap = bridge().accountSnapshot();
            return snap != null && snap.username != null ? snap.id : null;
        }

        /**
         * 附加自定义 SIP 头：REGISTER 头粘性注入引擎（每次注册携带直到
         * 排除）；INVITE 头仅记录（呼出 X-REQUEST-ID 走 callMake 专用通道）。
         */
        public static void includeNonStandardSipHeader(int accountIndex, String method,
                                                       String what, String name, String value) {
            bridge().includeNonStandardSipHeader(accountIndex, method, what, name, value);
        }

        /** 排除自定义 SIP 头（REGISTER 头即时撤除） */
        public static void excludeNonStandardSipHeader(int accountIndex, String method,
                                                       String what, String name) {
            bridge().excludeNonStandardSipHeader(accountIndex, method, what, name);
        }
    }

    /* ================================================================== */
    /* Notifications                                                      */
    /* ================================================================== */

    /**
     * 通知模块。update(Notification) 直接经 NotificationManager 发布；
     * ⚠️ id 取 App 的 NotificationIds.REGISTRATION_STATUS(1003)——App 侧
     * clearRegistrationNotification 按 1003 取消，两端必须一致。
     */
    public static final class Notifications {

        /** App NotificationIds.REGISTRATION_STATUS（耦合值，见类注释） */
        private static final int REGISTRATION_NOTIFICATION_ID = 1003;

        /** 更新常驻通知（null = 取消） */
        public static void update(Notification notification) {
            try {
                NotificationManager nm = AndroidUtil.getSystemService(NotificationManager.class);
                if (nm == null) {
                    return;
                }
                if (notification != null) {
                    nm.notify(REGISTRATION_NOTIFICATION_ID, notification);
                } else {
                    nm.cancel(REGISTRATION_NOTIFICATION_ID);
                }
            } catch (Throwable t) {
                android.util.Log.w(TAG, "Notifications.update failed: " + t);
            }
        }

        /** 推送子模块 */
        public static final class Push {

            /** FCM token 登记：SDK 存储并上报 uc-push（凭证就绪时；注册成功补报） */
            public static void setRegistrationId(String registrationId) {
                SdkBridge.get().setPushToken(registrationId);
            }

            /** 推送到达：唤醒注册（引擎就绪 + re-REGISTER，携带已注入的
             *  REGISTER 自定义头） */
            public static boolean handle(cz.acrobits.ali.Xml pushData, boolean highPriority) {
                try {
                    return SdkBridge.get().wakeupByPush();
                } catch (Throwable t) {
                    android.util.Log.w(TAG, "Push.handle failed: " + t);
                    return false;
                }
            }
        }
    }

    /* ================================================================== */
    /* Log                                                                */
    /* ================================================================== */

    /** SDK 日志模块（环形缓冲 + 自定义 Sink） */
    public static final class Log {

        /** 自定义日志输出流（null = 摘除） */
        public static void setCustomSink(OutputStream sink) {
            SdkBridge.get().setLogSink(sink);
        }

        /** 日志缓冲内容（引擎日志 + SDK 通道日志） */
        public static String get() {
            return SdkBridge.get().logBuffer();
        }

        /** 清空日志缓冲 */
        public static void clear() {
            SdkBridge.get().clearLogBuffer();
        }

        /** 写入 SDK 日志通道（引擎侧经 SdkBridge 自动进入） */
        public static void append(String msg) {
            SdkBridge.get().appendLog(msg);
        }
    }

    /* ================================================================== */
    /* Events                                                             */
    /* ================================================================== */

    /** 事件模块 */
    public static final class Events {

        /** 事件提交结果 */
        public enum PostResult {
            SUCCESS, FAILURE, NOT_READY
        }

        /** 提交事件（CallEvent = 拨号；MessageEvent = 仅记录） */
        public static PostResult post(Event event) {
            if (event == null) {
                return PostResult.FAILURE;
            }
            if (event instanceof CallEvent) {
                return SdkBridge.get().postCallEvent((CallEvent) event)
                        ? PostResult.SUCCESS : PostResult.FAILURE;
            }
            if (event instanceof MessageEvent) {
                return SdkBridge.get().postMessageEvent((MessageEvent) event)
                        ? PostResult.SUCCESS : PostResult.FAILURE;
            }
            return PostResult.FAILURE;
        }
    }

    /* ================================================================== */
    /* State                                                              */
    /* ================================================================== */

    /** SDK 状态模块（respawn = 引擎重建 + 账号恢复） */
    public static final class State {

        /** 重启 SDK（销毁引擎 → 重建 → 按账号快照重注册） */
        public static void respawn() {
            SdkBridge.get().respawn();
        }
    }
}
