package cz.acrobits.libsoftphone.support;

import android.os.Handler;
import android.os.Looper;

/**
 * SDK 终止任务（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面（NovoStateManager.terminate）：
 * object : TerminateTask() { override fun onTerminated() {...} } →
 * execute() →（终止完成）onTerminated() 回调；invokeOnCancellation → cancel()。
 *
 * 实现：execute() 关停引擎（异步收尾后主线程回调 onTerminated，给引擎
 * 1.5s 完成销毁链）；cancel() 后不再回调。
 */
public class TerminateTask {

    private static final long TERMINATE_SETTLE_MS = 1500;

    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private volatile boolean mCancelled;

    /** 执行终止（任意线程可调；完成经 onTerminated 主线程回调） */
    public void execute() {
        try {
            com.yeastar.sipcore.SdkBridge.get().shutdown();
        } catch (Throwable ignored) {
        }
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (!mCancelled) {
                    try {
                        onTerminated();
                    } catch (Throwable t) {
                        android.util.Log.w("Acrobits.TerminateTask", "onTerminated failed: " + t);
                    }
                }
            }
        }, TERMINATE_SETTLE_MS);
    }

    /** 取消（挂起等待方协同取消） */
    public void cancel() {
        mCancelled = true;
    }

    /** 终止完成回调（子类覆盖） */
    protected void onTerminated() {
    }
}
