package com.novosdk.ali;

/**
 * SDK 侧日志器（NovoSDK API 层，Acrobits 后端）。
 *
 * 直落 android logcat，tag 前缀 Novosdk.（与 Instance/ObserverBridge 等
 * adapter 内部日志同前缀）。**不转发真身 cz.acrobits.ali.Log**：真身走
 * LogSinkFactory 的 DisableableLogSink，其 isDebugBuild 硬编码 false，
 * native 引擎完成初始化前所有输出仅进内存缓存、logcat 收不到（2026-11-06
 * 代码审查实证真机排障全盲）。SDK 全局日志缓冲/自定义 Sink 走
 * {@code Instance.Log}（LogModule），与本类无关。
 */
public class Log {

    private final String mTag;

    public Log(Class<?> cls) {
        this(cls != null ? cls.getSimpleName() : "Novosdk");
    }

    public Log(String tag) {
        mTag = "Novosdk." + (tag != null ? tag : "Log");
    }

    public void info(String msg) {
        android.util.Log.i(mTag, msg != null ? msg : "");
    }

    public void warning(String msg) {
        android.util.Log.w(mTag, msg != null ? msg : "");
    }

    public void error(String msg) {
        android.util.Log.e(mTag, msg != null ? msg : "");
    }

    /** 格式 + 异常（App 侧惯用 LOG.error("...%s", e)） */
    public void error(String fmt, Throwable t) {
        android.util.Log.e(mTag, fmt != null ? fmt : "", t);
    }

    public String getTag() {
        return mTag;
    }
}
