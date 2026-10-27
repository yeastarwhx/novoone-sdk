package cz.acrobits.libsoftphone;

import cz.acrobits.libsoftphone.key.IncomingCallsMode;

/**
 * SDK 偏好基类（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * Instance.init 以宿主传入的 preferencesClass（如 NovoPreferences）反射
 * 实例化，Instance.preferences 字段持有该实例。App 访问的偏好成员全部
 * 定义在本基类（Kotlin 经 Instance.preferences.xxx 直达）。
 *
 * 运行语义：引擎相关项（回声消除 / 增益）转发 SipWebrtcEngine，其余为
 * 内存记录（callIntegrationMode / incomingCallsMode 等本引擎无对应机制）。
 */
public class Preferences {

    /**
     * 单项偏好：set 写入（立即生效或记录），get 读取当前值。
     */
    public static class Preference<T> {

        private T mValue;

        public void set(T value) {
            mValue = value;
        }

        public T get() {
            return mValue;
        }

        /** 默认值覆盖（仅安装期；App 主链路未使用，保留形态） */
        public void overrideDefault(T value) {
            if (mValue == null) {
                mValue = value;
            }
        }
    }

    /** 流量日志（详细 SIP 消息日志开关；本引擎记录即生效） */
    public final Preference<Boolean> trafficLogging = new Preference<Boolean>();

    /** 播放块时长（ms；引擎缓冲自适应，仅记录） */
    public final Preference<Integer> playbackBlockDurationInMilliseconds = new Preference<Integer>();

    /** User-Agent 覆盖（引擎在 engineStart 时自行组装统一 UA；此处记录备用） */
    public final Preference<String> userAgentOverride = new Preference<String>();

    /** 系统通话集成模式（off / bestEffort；Telecom 集成由宿主 Manifest 决定，仅记录） */
    public final Preference<String> callIntegrationMode = new Preference<String>();

    /** 来电模式（STANDARD 长连接 / PUSH 推送唤醒；本引擎恒 STANDARD 语义） */
    public final Preference<IncomingCallsMode> incomingCallsMode = new Preference<IncomingCallsMode>();

    /** 回声消除开关（转发引擎 setEchoCancelEnabled） */
    public final Preference<Boolean> echoSuppression = new Preference<Boolean>() {
        @Override
        public void set(Boolean value) {
            super.set(value);
            if (value != null) {
                try {
                    com.yeastar.sipcore.SipWebrtcEngine.getInstance()
                            .setEchoCancelEnabled(value);
                } catch (Throwable ignored) {
                }
            }
        }
    };

    /** 麦克风增益（App 契约 -10..10 线性；转发引擎 setMicGain） */
    public final Preference<Integer> volumeBoostMicrophone = new Preference<Integer>() {
        @Override
        public void set(Integer value) {
            super.set(value);
            if (value != null) {
                try {
                    /* -10..10 线性 → AudioTrack.setVolume 0..10 标度：
                     * max(0.1, (value + 10) / 2) 保底可闻 */
                    double gain = Math.max(0.1, (value + 10) / 2.0);
                    com.yeastar.sipcore.SipWebrtcEngine.getInstance().setMicGain(gain);
                } catch (Throwable ignored) {
                }
            }
        }
    };

    /** 播放增益（引擎未提供播放端增益，仅记录） */
    public final Preference<Integer> volumeBoostPlayback = new Preference<Integer>();

    /** 子类覆盖默认值入口（NovoPreferences.overrideDefaults） */
    protected void overrideDefaults() {
    }

    public Preferences() {
        overrideDefaults();
    }
}
