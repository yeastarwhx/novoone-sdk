package cz.acrobits.ali;

/**
 * SDK 侧日志器（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 用法：new Log(Class) / new Log("tag") + info / warning / error。
 * 内部落 android logcat（tag 前缀 Acrobits，防与 App 日志混淆）。
 * SDK 全局日志缓冲/自定义 Sink 走 {@code Instance.Log}（LogModule），与本类无关。
 */
public class Log {

    private final String mTag;

    public Log(Class<?> cls) {
        this(cls != null ? cls.getSimpleName() : "Acrobits");
    }

    public Log(String tag) {
        mTag = "Acrobits." + (tag != null ? tag : "Log");
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
