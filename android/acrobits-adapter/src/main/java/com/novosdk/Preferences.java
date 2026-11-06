package com.novosdk;

/**
 * SDK 偏好基类（NovoSDK API 层，Acrobits 后端）。
 *
 * 形状对齐 :novosdk 自研实现（Preference&lt;T&gt; + set/get/overrideDefault/reset），
 * 内部经 Preference 包装真身 Preferences$Key——set 直写真身（26 形态由 Acrobits
 * SDK 消费偏好；126 形态的 userAgentOverride 额外转发引擎注入，26 无此链，
 * 写真身即达，语义等价）。
 *
 * 装配时序（宿主 NovoPreferences 为无参构造，App 代码固定）：
 * 1) Instance.init 反射构造宿主（走无参构造，字段为 null 包装）
 * 2) 真身 init 完成后，Instance 侧调 rebind(真身preferences) 二次装配——
 *    全部字段重新包装真身 Key，宿主读写自此直达真身
 */
public class Preferences {

    /** 真身偏好引用（rebind 后非 null） */
    cz.acrobits.libsoftphone.Preferences real;

    /**
     * 单项偏好：包装真身 Key 的转发。real 缺失（rebind 前）静默忽略。
     */
    public static class Preference<T> {

        private final cz.acrobits.libsoftphone.Preferences.Key<T> mReal;

        Preference(cz.acrobits.libsoftphone.Preferences.Key<T> real) {
            mReal = real;
        }

        public void set(T value) {
            if (mReal != null) {
                mReal.set(value);
            }
        }

        public T get() {
            return mReal != null ? mReal.get() : null;
        }

        /** 默认值覆盖（仅安装期；真身可能抛 TooLate 异常，防御吞掉） */
        public void overrideDefault(T value) {
            if (mReal != null) {
                try {
                    mReal.overrideDefault(value);
                } catch (Throwable ignored) {
                }
            }
        }

        /** 清除当前值恢复默认 */
        public void reset() {
            if (mReal != null) {
                mReal.reset();
            }
        }
    }

    private <T> Preference<T> wrap(cz.acrobits.libsoftphone.Preferences.Key<T> key) {
        return new Preference<T>(real != null ? key : null);
    }

    /* ---------------- 偏好字段（App 消费集，与 :novosdk 形状一致） ---------------- */

    public Preference<Boolean> trafficLogging;
    public Preference<Integer> playbackBlockDurationInMilliseconds;
    public Preference<String> userAgentOverride;
    public Preference<String> callIntegrationMode;
    /** 来电模式（NovoSDK 形状；rebind 时装配枚举↔String 转换桥） */
    public Preference<com.novosdk.key.IncomingCallsMode> incomingCallsMode = null;
    public Preference<Boolean> echoSuppression;
    public Preference<Integer> volumeBoostMicrophone;
    public Preference<Integer> volumeBoostPlayback;

    /** 子类覆盖默认值入口（宿主 NovoPreferences.overrideDefaults） */
    protected void overrideDefaults() {
    }

    /** 真身 init 完成后的二次装配（Instance 侧调用；包内可见） */
    void rebind(cz.acrobits.libsoftphone.Preferences r) {
        real = r;
        trafficLogging = wrap(r.trafficLogging);
        playbackBlockDurationInMilliseconds = wrap(r.playbackBlockDurationInMilliseconds);
        userAgentOverride = wrap(r.userAgentOverride);
        callIntegrationMode = wrap(r.callIntegrationMode);
        // incomingCallsMode：真身为 String（STANDARD/PUSH），NovoSDK 为枚举
        // ——专用包装做双向转换
        incomingCallsMode = new Preference<com.novosdk.key.IncomingCallsMode>(null) {
            private cz.acrobits.libsoftphone.Preferences.Key<String> key() {
                return real != null ? real.incomingCallsMode : null;
            }
            @Override
            public void set(com.novosdk.key.IncomingCallsMode value) {
                cz.acrobits.libsoftphone.Preferences.Key<String> k = key();
                if (k != null && value != null) {
                    k.set(value.name());
                }
            }
            @Override
            public com.novosdk.key.IncomingCallsMode get() {
                cz.acrobits.libsoftphone.Preferences.Key<String> k = key();
                if (k == null) {
                    return null;
                }
                try {
                    return com.novosdk.key.IncomingCallsMode.valueOf(k.get());
                } catch (IllegalArgumentException e) {
                    return null;
                }
            }
        };
        echoSuppression = wrap(r.echoSuppression);
        volumeBoostMicrophone = wrap(r.volumeBoostMicrophone);
        volumeBoostPlayback = wrap(r.volumeBoostPlayback);
        try {
            overrideDefaults();
        } catch (Throwable ignored) {
        }
    }
}
