package com.novosdk.telecom.compat;

import android.telecom.Connection;

import com.novosdk.event.CallEvent;

/**
 * Telecom Connection 工厂门面（按系统版本四档创建 + onSilence 拦截钩子）。
 *
 * <p>下沉来源（2026-11-10 connectionfactory-sinkdown 任务）：原为 App 侧
 * 寄生本包的同名 Java 文件（App 源码树占 SDK 包名继承包私有
 * ConnectionImplApi*）。下沉后分版判断经 {@link ConnectionCompat#pickLevel}
 * 单一来源（App/SDK 双份人工同步的崩溃级风险消除——分档错配会在低版本
 * 设备抛 NoSuchMethodError）；onSilence 拦截改钩子注入（SDK 零产品策略，
 * App 经 {@link #setOnSilenceListener} 注册）。</p>
 *
 * <p>消费面与原 App 寄生版完全一致：{@code create(CallEvent, boolean)}。
 * 26 形态（Acrobits）下 App 侧仍保留 cz.acrobits 包寄生版（闭源约束
 * 无解，至 Acrobits 退役），其已对齐 setOnSilenceListener 签名保证 App
 * 消费代码双形态编译一致。</p>
 */
public final class NovoConnectionFactory {

    /** onSilence 拦截钩子（App 注册；volatile 主线程写/Telecom 线程读） */
    private static volatile Runnable sOnSilenceListener;

    private NovoConnectionFactory() {
    }

    /**
     * 按系统版本创建对应层级的 Connection 子类，并经钩子拦截 onSilence。
     * 分档单一来源：ConnectionCompat.pickLevel（未来加档只改那里）。
     */
    public static Connection create(CallEvent callEvent, boolean selfManaged) {
        switch (ConnectionCompat.pickLevel(android.os.Build.VERSION.SDK_INT)) {
            case ConnectionCompat.LEVEL_API35:
                return new InterceptingApi35(callEvent, selfManaged);
            case ConnectionCompat.LEVEL_API34:
                return new InterceptingApi34(callEvent, selfManaged);
            case ConnectionCompat.LEVEL_API26:
                return new InterceptingApi26(callEvent, selfManaged);
            default:
                return new InterceptingApi23(callEvent);
        }
    }

    /**
     * 注册 onSilence 拦截钩子（用户按音量键静音来电铃声的定制点）。
     * 未注册时 onSilence 为空实现（SDK 不内置策略）。
     */
    public static void setOnSilenceListener(Runnable listener) {
        sOnSilenceListener = listener;
    }

    /** API 35+（Android 15+）设备层级 */
    static final class InterceptingApi35 extends ConnectionImplApi35 {

        InterceptingApi35(CallEvent callEvent, boolean selfManaged) {
            super(callEvent, selfManaged);
        }

        @Override
        public void onSilence() {
            Runnable l = sOnSilenceListener;
            if (l != null) {
                l.run();
            }
        }
    }

    /** API 34（Android 14）设备层级 */
    static final class InterceptingApi34 extends ConnectionImplApi34 {

        InterceptingApi34(CallEvent callEvent, boolean selfManaged) {
            super(callEvent, selfManaged);
        }

        @Override
        public void onSilence() {
            Runnable l = sOnSilenceListener;
            if (l != null) {
                l.run();
            }
        }
    }

    /** API 26–33（Android 8.0–13）设备层级 */
    static final class InterceptingApi26 extends ConnectionImplApi26 {

        InterceptingApi26(CallEvent callEvent, boolean selfManaged) {
            super(callEvent, selfManaged);
        }

        @Override
        public void onSilence() {
            Runnable l = sOnSilenceListener;
            if (l != null) {
                l.run();
            }
        }
    }

    /** API 26 以下设备层级（构造器无 selfManaged 参数，对齐 SDK 工厂） */
    static final class InterceptingApi23 extends ConnectionImplApi23 {

        InterceptingApi23(CallEvent callEvent) {
            super(callEvent);
        }

        @Override
        public void onSilence() {
            Runnable l = sOnSilenceListener;
            if (l != null) {
                l.run();
            }
        }
    }
}
