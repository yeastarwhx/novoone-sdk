package com.yeastar.sipcore;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * SIP 引擎前台 Service（推送唤醒链路的"优雅注销"载体，SDK 内置）。
 *
 * 作用：持有前台 Service 使"用户划掉任务"时进程有存活窗口，
 * onTaskRemoved 中同步发出 un-REGISTER（Expires: 0）——服务器据此
 * 清除注册绑定，后续呼入才会走"FCM 推送 + P-hint 唤醒注册"模式下发
 * INVITE。缺失此环节则服务器保留僵尸绑定（expires 内有效），呼入按
 * "在线直发"发往已死的 TCP 连接，失败后不回落推送模式。
 *
 * 生命周期：注册成功（SdkBridge.onRegisterState 200）启动；登出
 * （clearAccount）/ 引擎关停（shutdown）停止。声明在本模块 AAR
 * manifest，宿主 App 零改动。
 *
 * onTaskRemoved 反注册为轻量语义：直调引擎 accountUnregister（删号 +
 * Expires:0），不删 SdkBridge 账号快照——FCM 唤醒冷注册依赖快照全参。
 */
public class SipForegroundService extends Service {

    private static final String TAG = "SipForegroundService";

    /** 前台通知 id（独立于 App 通知位，避免互踩） */
    private static final int NOTIFICATION_ID = 2001;

    private static final String CHANNEL_ID = "sip_service_channel";

    /** 已请求启动（CAS 抑制并发双发；失败/销毁复位） */
    private static final java.util.concurrent.atomic.AtomicBoolean sStartRequested =
            new java.util.concurrent.atomic.AtomicBoolean(false);

    /** 启动前台 Service（幂等）。调用方须在 App 前台或 FCM 处理豁免窗口
     *  （Android 12+ 后台 FGS 启动限制），失败仅记日志不影响主流程，
     *  下次注册成功时机重试 */
    public static void start() {
        if (!sStartRequested.compareAndSet(false, true)) {
            return;
        }
        try {
            Context ctx = cz.acrobits.ali.AndroidUtil.getApplicationContext();
            ctx.startForegroundService(new Intent(ctx, SipForegroundService.class));
        } catch (Throwable t) {
            android.util.Log.w(TAG, "start failed (background FGS restriction?): " + t);
            sStartRequested.set(false);
        }
    }

    /** 停止（登出/引擎关停） */
    public static void stop() {
        try {
            Context ctx = cz.acrobits.ali.AndroidUtil.getApplicationContext();
            ctx.stopService(new Intent(ctx, SipForegroundService.class));
        } catch (Throwable ignored) {
        }
        sStartRequested.set(false);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(new NotificationChannel(CHANNEL_ID,
                        "SIP", NotificationManager.IMPORTANCE_MIN));
            }
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        int icon = getApplicationInfo().icon;
        String label;
        try {
            label = String.valueOf(getPackageManager().getApplicationLabel(getApplicationInfo()));
        } catch (Throwable t) {
            label = "SIP";
        }
        builder.setSmallIcon(icon != 0 ? icon : android.R.drawable.stat_sys_phone_call)
                .setContentTitle(label)
                .setContentText("SIP")
                .setOngoing(true);
        Notification notification = builder.build();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                /* phoneCall|microphone：phoneCall 无 Android 15 dataSync 配额
                 * 限制；microphone 支持通话中退后台的采集（组合类型要求
                 * MANAGE_OWN_CALLS + RECORD_AUDIO 运行时已授，登录场景满足） */
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                                | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Throwable t) {
            /* microphone 型 while-in-use 启动限制等：降级纯 phoneCall 重试
             * （保活优先，麦克风限制接受——回前台恢复） */
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL);
                } else {
                    startForeground(NOTIFICATION_ID, notification);
                }
            } catch (Throwable t2) {
                android.util.Log.w(TAG, "startForeground failed: " + t2);
            }
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        /* START_STICKY：进程被系统回收后拉起（重新走引擎启动即注册链路） */
        return START_STICKY;
    }

    /**
     * 用户从最近任务划掉 App：进程即将被终止——优雅注销的最后窗口。
     * 同步发出 un-REGISTER（JNI 直调，TCP write 即走），服务器收到后
     * 清除绑定，后续呼入进入推送模式。
     */
    @Override
    public void onTaskRemoved(Intent rootIntent) {
        try {
            SipWebrtcEngine engine = SipWebrtcEngine.getInstance();
            if (engine.isStarted() && engine.getAccId() >= 0) {
                engine.accountUnregister();
                android.util.Log.i(TAG, "un-REGISTER sent on task removed");
            }
        } catch (Throwable t) {
            android.util.Log.w(TAG, "un-REGISTER failed: " + t);
        }
        stopSelf();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        sStartRequested.set(false);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
