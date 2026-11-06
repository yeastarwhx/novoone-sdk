package com.novosdk;

import android.app.Notification;
import android.content.Context;

import com.novosdk.data.AudioRoute;
import com.novosdk.data.Call;
import com.novosdk.data.CallStatistics;
import com.novosdk.data.MediaStatus;
import com.novosdk.data.NetworkStatus;
import com.novosdk.event.CallEvent;
import com.novosdk.support.Listeners;
import com.novosdk.ali.Xml;

import java.io.OutputStream;
import java.util.List;

/**
 * NovoSDK softphone API 门面入口（Instance，Acrobits 后端）。
 *
 * 形状与 :novosdk 自研实现完全一致（类名/嵌套类/方法签名），内部经
 * {@link Bridge} 转换后委托 cz.acrobits.libsoftphone.Instance 真身。
 *
 * 装配时序：init() 构造真身偏好 → 反射构造宿主 preferencesClass →
 * 真身 init → 宿主 rebind(真身偏好)——宿主 NovoPreferences 的无参构造
 * 在真身就绪前跑，rebind 后读写直达真身（见 Preferences.rebind）。
 *
 * S3 真机回归完成（2026-11-04）：呼出/呼入/hold(呼入)/注册/回调全链
 * 验证通过；剩余行为边界见各方法注释与任务 verification.md。
 */
public final class Instance {

    /** 宿主偏好实例（init 反射构造；App 经 Instance.preferences 访问） */
    public static Preferences preferences;

    /** App 观察者（骨架期仅持有；真身回调→NovoSDK 分发桥在委托化阶段接线） */
    private static Listeners sObserver;

    private Instance() {
    }

    /* ---------------- 生命周期 ---------------- */

    public static void loadLibrary(Context context) {
        // 真身 throws Throwable；NovoSDK 形状无 throws（App 调用不捕获）——
        // 包装为运行时异常抛出，保持签名兼容同时不吞加载失败
        try {
            cz.acrobits.libsoftphone.Instance.loadLibrary(context);
        } catch (Throwable t) {
            throw new IllegalStateException("libsoftphone load failed", t);
        }
    }

    /**
     * SDK 初始化。provisioning 树按 NovoSDK Xml 结构传入（App 构造），
     * 序列化为字符串后由真身重新解析（树级深转换的骨架替代——真身
     * ali.Xml 解析能力可靠，避免手写树拷贝）。
     */
    public static void init(Context context, Xml provisioning,
                            Class<?> preferencesClass) throws Throwable {
        // 1) 宿主偏好（无参构造，先于真身就绪）
        Object host = null;
        try {
            host = preferencesClass.getDeclaredConstructor().newInstance();
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.Instance", "preferences class failed: " + t);
        }
        // 2) 真身偏好载体 + provisioning
        cz.acrobits.ali.Xml realXml = AcrobitsXml.fromNovosdk(provisioning);
        boolean ok = cz.acrobits.libsoftphone.Instance.init(context, realXml,
                cz.acrobits.libsoftphone.Preferences.class);
        android.util.Log.i("Novosdk.Instance", "real init ok=" + ok
                + ", real prefs=" + (cz.acrobits.libsoftphone.Instance.preferences != null));
        // 3) 宿主 rebind 真身偏好
        if (host instanceof Preferences
                && cz.acrobits.libsoftphone.Instance.preferences != null) {
            preferences = (Preferences) host;
            preferences.rebind(cz.acrobits.libsoftphone.Instance.preferences);
        }
        // 4) Activity 生命周期追踪装配（对齐 :novosdk SdkBridge.init——缺失时
        // activityList 恒空，App 前台来电仲裁 isAnyActive() 恒 false，前台
        // 全屏来电退化为后台横幅，2026-11-06 代码审查修复）
        if (context != null && context.getApplicationContext()
                instanceof android.app.Application) {
            com.novosdk.support.lifecycle.LifecycleTracker.install(
                    (android.app.Application) context.getApplicationContext());
        }
    }

    /**
     * 观察者注册：NovoSDK Listeners 经 ObserverBridge 转译注册到真身
     * （真身回调→转换→NovoSDK dispatchXxx→App SAM 监听）。
     */
    public static void setObserver(Listeners listeners) {
        sObserver = listeners;
        cz.acrobits.libsoftphone.Instance.setObserver(ObserverBridge.create(listeners));
    }

    /* ================================================================== */
    /* State（重启工具）                                                  */
    /* ================================================================== */

    public static final class State {

        private State() {
        }

        /**
         * 重启 SDK。真身有同签名 native API（javap 实证 Instance$State
         * 为枚举类且含 respawn/terminate/isTerminating 全套）——直接转发。
         * 此前空实现导致 NovoStateManager 的错误恢复/配置变更重启在
         * 26 形态静默失效（2026-11-05 审计修复）。
         */
        public static void respawn() {
            cz.acrobits.libsoftphone.Instance.State.respawn();
        }
    }

    /* ================================================================== */
    /* Calls                                                              */
    /* ================================================================== */

    public static final class Calls {

        private Calls() {
        }

        /** 组呼（方法面镜像真身 Conferences；26 语义=真身真组呼模型） */
        public static final class Conferences {

            private Conferences() {
            }

            public static String get(CallEvent event) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.get(Bridge.unwrap(event));
            }

            public static CallEvent[] getCalls(String groupId) {
                return Bridge.wrapAllArray(
                        cz.acrobits.libsoftphone.Instance.Calls.Conferences.getCalls(groupId));
            }

            public static String[] list() {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.list();
            }

            public static String[] list(String name) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.list(name);
            }

            public static int getSize(String groupId) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.getSize(groupId);
            }

            public static int getSize(CallEvent event) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.getSize(
                        Bridge.unwrap(event));
            }

            public static String getActive() {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.getActive();
            }

            public static void setActive(String groupId) {
                    cz.acrobits.libsoftphone.Instance.Calls.Conferences.setActive(groupId);
            }

            public static void setActive(CallEvent event) {
                cz.acrobits.libsoftphone.Instance.Calls.Conferences.setActive(Bridge.unwrap(event));
            }

            public static void move(CallEvent event, String groupId) {
                cz.acrobits.libsoftphone.Instance.Calls.Conferences.move(Bridge.unwrap(event), groupId);
            }

            public static void split(CallEvent event, boolean close) {
                cz.acrobits.libsoftphone.Instance.Calls.Conferences.split(Bridge.unwrap(event), close);
            }

            public static int count() {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.count();
            }

            public static String generate(String name) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.generate(name);
            }

            public static CallEvent[] getCalls(CallEvent event) {
                return Bridge.wrapAllArray(
                        cz.acrobits.libsoftphone.Instance.Calls.Conferences.getCalls(
                                Bridge.unwrap(event)));
            }

            public static void transfer(CallEvent event, CallEvent newCall) {
                cz.acrobits.libsoftphone.Instance.Calls.Conferences.transfer(
                        Bridge.unwrap(event), Bridge.unwrap(newCall));
            }

            public static boolean attendedTransfer(CallEvent from, CallEvent to) {
                return cz.acrobits.libsoftphone.Instance.Calls.Conferences.attendedTransfer(
                        Bridge.unwrap(from), Bridge.unwrap(to));
            }
        }

        public static List<CallEvent> getActive() {
            return Bridge.wrapAll(cz.acrobits.libsoftphone.Instance.Calls.getActive());
        }

        public static Call.State getState(CallEvent event) {
            return Bridge.convertEnum(
                    cz.acrobits.libsoftphone.Instance.Calls.getState(Bridge.unwrap(event)),
                    Call.State.class);
        }

        public static boolean answerIncoming(CallEvent event, Call.DesiredMedia media) {
            // NovoSDK DesiredMedia 为无状态工厂类（无法判别实例来源）；
            // 26 形态语音通话为设计终态——固定 voiceOnly
            boolean ok = cz.acrobits.libsoftphone.Instance.Calls.answerIncoming(
                    Bridge.unwrap(event),
                    cz.acrobits.libsoftphone.data.Call.DesiredMedia.voiceOnly());
            // 返回值探针（推送唤醒接听诊断）：真身拒绝应答时 App 层无 200 OK 可发
            android.util.Log.i("Novosdk.Calls", "answerIncoming eventId=" + event.getEventId()
                    + " -> " + ok);
            return ok;
        }

        public static void close(CallEvent event) {
            cz.acrobits.libsoftphone.Instance.Calls.close(Bridge.unwrap(event));
        }

        public static boolean rejectIncomingHere(CallEvent event, Call.RejectReason reason) {
            return cz.acrobits.libsoftphone.Instance.Calls.rejectIncomingHere(
                    Bridge.unwrap(event), Bridge.unwrapRejectReason(reason));
        }

        public static boolean ignoreIncoming(CallEvent event) {
            return cz.acrobits.libsoftphone.Instance.Calls.ignoreIncoming(Bridge.unwrap(event));
        }

        public static Call.HoldStates isHeld(CallEvent event) {
            return Bridge.wrapHoldStates(
                    cz.acrobits.libsoftphone.Instance.Calls.isHeld(Bridge.unwrap(event)));
        }

        public static void setHeld(CallEvent event, boolean held) {
            cz.acrobits.libsoftphone.Instance.Calls.setHeld(Bridge.unwrap(event), held);
        }

        public static CallStatistics getStatistics(CallEvent event) {
            return Bridge.wrapStatistics(
                    cz.acrobits.libsoftphone.Instance.Calls.getStatistics(Bridge.unwrap(event)));
        }

        public static MediaStatus getMediaStatus(CallEvent event) {
            return Bridge.wrapMediaStatus(
                    cz.acrobits.libsoftphone.Instance.Calls.getMediaStatus(Bridge.unwrap(event)));
        }

        public static NetworkStatus getNetworkStatus(CallEvent event) {
            return Bridge.wrapNetworkStatus(
                    cz.acrobits.libsoftphone.Instance.Calls.getNetworkStatus(Bridge.unwrap(event)));
        }

        /**
         * 应答/消息头读取（真身 native 能力）。
         * 直接取真身节点值构造"名-值"节点——不经 XML 文本往返（往返路径的
         * parse() 不写叶文本值，App 侧 getValue() 恒 null，2026-11-06 审查
         * 实证 SIP 头提取在 26 形态全静默失效）。
         */
        public static Xml findSipHeader(CallEvent event, String name) {
            cz.acrobits.ali.Xml real = cz.acrobits.libsoftphone.Instance.Calls.findSipHeader(
                    Bridge.unwrap(event), name);
            if (real == null) {
                return null;
            }
            Xml out = new Xml(name);
            out.setValue(real.getValue());
            return out;
        }


    }

    /* ================================================================== */
    /* Audio                                                              */
    /* ================================================================== */

    public static final class Audio {

        private Audio() {
        }

        public static void setMuted(boolean muted) {
            cz.acrobits.libsoftphone.Instance.Audio.setMuted(muted);
        }

        public static boolean isMuted() {
            return cz.acrobits.libsoftphone.Instance.Audio.isMuted();
        }

        public static void dtmfOn(byte digit) {
            cz.acrobits.libsoftphone.Instance.Audio.dtmfOn(digit);
        }

        public static void dtmfOff() {
            cz.acrobits.libsoftphone.Instance.Audio.dtmfOff();
        }

        public static void setCallAudioRoute(AudioRoute route) {
            cz.acrobits.libsoftphone.Instance.Audio.setCallAudioRoute(
                    Bridge.convertEnum(route, cz.acrobits.libsoftphone.data.AudioRoute.class));
        }

        public static AudioRoute getCallAudioRoute() {
            return Bridge.convertEnum(
                    cz.acrobits.libsoftphone.Instance.Audio.getCallAudioRoute(),
                    AudioRoute.class);
        }

        public static AudioRoute[] getAvailableCallAudioRoutes() {
            cz.acrobits.libsoftphone.data.AudioRoute[] real =
                    cz.acrobits.libsoftphone.Instance.Audio.getAvailableCallAudioRoutes();
            if (real == null) {
                return new AudioRoute[0];
            }
            AudioRoute[] out = new AudioRoute[real.length];
            for (int i = 0; i < real.length; i++) {
                out[i] = Bridge.convertEnum(real[i], AudioRoute.class);
            }
            return out;
        }
    }

    /* ================================================================== */
    /* Events                                                             */
    /* ================================================================== */

    public static final class Events {

        private Events() {
        }

        /** 拨号入口：App 构造的 NovoSDK CallEvent（RemoteUser+transients）转真身后 post */
        public static PostResult post(CallEvent event) {
            cz.acrobits.libsoftphone.event.CallEvent real = Bridge.unwrap(event);
            // 不做 URI 补全（线上直连同款输入直入真身，裸号码由真身 native 补域）：
            // S3 时期的 completeDialUri 是账户保存 bug（saveAccount 双参构造缺失）
            // 时期的错误方向修复，账户修复后按线上一致原则移除（2026-11-06）
            int rc = cz.acrobits.libsoftphone.Instance.Events.post(real);
            return rc > 0 ? PostResult.SUCCESS : PostResult.FAILURE;
        }

        /** 与 :novosdk 形状对齐的结果枚举（值语义对齐真身 post 返回码） */
        public enum PostResult {
            SUCCESS, FAILURE
        }
    }

    /* ================================================================== */
    /* Log                                                                */
    /* ================================================================== */

    public static final class Log {

        private Log() {
        }

        public static String get() {
            return cz.acrobits.libsoftphone.Instance.Log.get();
        }

        public static void clear() {
            cz.acrobits.libsoftphone.Instance.Log.clear();
        }

        public static void setCustomSink(OutputStream sink) {
            cz.acrobits.libsoftphone.Instance.Log.setCustomSink(sink);
        }
    }

    /* ================================================================== */
    /* Notifications                                                      */
    /* ================================================================== */

    public static final class Notifications {

        private Notifications() {
        }

        public static void update(Notification notification) {
            cz.acrobits.libsoftphone.Instance.Notifications.update(notification);
        }

        public static final class Push {

            private Push() {
            }

            public static void setRegistrationId(String id) {
                cz.acrobits.libsoftphone.Instance.Notifications.Push.setRegistrationId(id);
            }

            public static boolean handle(Xml pushData, boolean foreground) {
                // 真身 handle 吃 ali.Xml——NovoSDK Xml 序列化桥同 init
                return cz.acrobits.libsoftphone.Instance.Notifications.Push.handle(
                        AcrobitsXml.fromNovosdk(pushData), foreground);
            }
        }
    }
    /* ================================================================== */
    /* Registration                                                       */
    /* ================================================================== */

    /**
     * 账户管理（Acrobits 后端）。方法面镜像真身 Instance$Registration，
     * AccountXml 经 {@link AccountBridge} XML 往返桥转换。
     */
    public static final class Registration {

        private Registration() {
        }

        public static String saveAccount(com.novosdk.account.AccountXml account) {
            return cz.acrobits.libsoftphone.Instance.Registration.saveAccount(
                    AccountBridge.toReal(account));
        }

        public static void deleteAccount(String accountId) {
            cz.acrobits.libsoftphone.Instance.Registration.deleteAccount(accountId);
        }

        public static com.novosdk.account.AccountXml getAccount(String accountId) {
            return AccountBridge.fromReal(
                    cz.acrobits.libsoftphone.Instance.Registration.getAccount(accountId));
        }

        public static com.novosdk.account.AccountXml getAccount(int index) {
            return AccountBridge.fromReal(
                    cz.acrobits.libsoftphone.Instance.Registration.getAccount(index));
        }

        public static String[] getAccounts() {
            return cz.acrobits.libsoftphone.Instance.Registration.getAccounts();
        }

        public static String[] getEnabledAccounts() {
            return cz.acrobits.libsoftphone.Instance.Registration.getEnabledAccounts();
        }

        public static int getAccountCount() {
            return cz.acrobits.libsoftphone.Instance.Registration.getAccountCount();
        }

        public static int getAccountIndex(String accountId) {
            return cz.acrobits.libsoftphone.Instance.Registration.getAccountIndex(accountId);
        }

        public static String getAccountId(int index) {
            return cz.acrobits.libsoftphone.Instance.Registration.getAccountId(index);
        }

        public static void updateAll() {
            cz.acrobits.libsoftphone.Instance.Registration.updateAll();
        }

        public static com.novosdk.account.AccountXml getDefaultAccount() {
            return AccountBridge.fromReal(
                    cz.acrobits.libsoftphone.Instance.Registration.getDefaultAccount());
        }

        public static String getDefaultAccountId() {
            return cz.acrobits.libsoftphone.Instance.Registration.getDefaultAccountId();
        }

        /**
         * 自定义头注入（NovoSDK 自研头通道 API，App 经 NovoTraceId 注入
         * REGISTER 推送双头）。真身有同签名 API（javap 实证）——直接转发：
         * SBC 推送呼叫契约要求 re-REGISTER 携带 X-Nov-Push-Session/X-REQUEST-ID
         * 双头关联 pending 呼叫后才下发 INVITE；此前空实现导致推送唤醒场景
         * INVITE 永不到达、SipPushedCall 接答后超时判 Missed（2026-11-05 根因）。
         */
        public static void includeNonStandardSipHeader(int accountIndex, String method,
                                                       String what, String name, String value) {
            cz.acrobits.libsoftphone.Instance.Registration.includeNonStandardSipHeader(
                    accountIndex, method, what, name, value);
        }

        /** 自定义头撤除（同上，转发真身） */
        public static void excludeNonStandardSipHeader(int accountIndex, String method,
                                                       String what, String name) {
            cz.acrobits.libsoftphone.Instance.Registration.excludeNonStandardSipHeader(
                    accountIndex, method, what, name);
        }
    }

}
