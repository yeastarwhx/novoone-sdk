package com.novosdk.support;

import android.os.Handler;
import android.os.Looper;

/**
 * SDK 终止任务（NovoSDK softphone API 层）。
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
    private Runnable mPendingCallback;

    /** 执行终止（任意线程可调；完成经 onTerminated 主线程回调） */
    public void execute() {
        try {
            com.yeastar.sipcore.SdkBridge.get().shutdown();
        } catch (Throwable ignored) {
        }
        mPendingCallback = new Runnable() {
            @Override
            public void run() {
                if (!mCancelled) {
                    try {
                        onTerminated();
                    } catch (Throwable t) {
                        android.util.Log.w("Novosdk.TerminateTask", "onTerminated failed: " + t);
                    }
                }
            }
        };
        mHandler.postDelayed(mPendingCallback, TERMINATE_SETTLE_MS);
    }

    /** 取消（挂起等待方协同取消；同时移除滞留的主线程回调） */
    public void cancel() {
        mCancelled = true;
        Runnable pending = mPendingCallback;
        if (pending != null) {
            mHandler.removeCallbacks(pending);
        }
    }

    /** 终止完成回调（子类覆盖） */
    protected void onTerminated() {
    }
}
