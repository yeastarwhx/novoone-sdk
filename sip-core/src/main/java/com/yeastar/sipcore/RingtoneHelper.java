package com.yeastar.sipcore;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.media.ToneGenerator;
import android.os.Build;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.util.Log;

/**
 * 来电铃声 / 回铃音播放（静态工具类，引擎在主线程调用）。
 *
 * - playRingtone：系统默认铃声（循环）+ 振动 —— 来电振铃期使用；
 *   停止时机由引擎控制（接听 / 拒接 / 对端取消）。
 * - playBackTone：回铃音（ToneGenerator，近似 440Hz 长音节奏）——
 *   呼出 180 Ringing 期使用，CONFIRMED / 终态停止。
 *
 * 线程模型：仅主线程调用（内部状态无锁）；全部方法可重入（重复
 * play 先停旧的再播新的，stop 无铃声时为 no-op）。
 */
public final class RingtoneHelper {

    private static final String TAG = "RingtoneHelper";

    /** 振动节奏：振动 600ms / 停 600ms 循环（对齐系统来电节奏） */
    private static final long[] VIBRATE_PATTERN = {0, 600, 600};

    private static Ringtone ringtone;
    private static Vibrator vibrator;
    private static ToneGenerator backTone;

    private RingtoneHelper() {
    }

    /* ------------------------------------------------------------------ */
    /* 来电铃声 + 振动                                                     */
    /* ------------------------------------------------------------------ */

    /** 播放系统默认来电铃声（循环）并开始振动 */
    public static void playRingtone(Context context) {
        if (context == null) {
            return;
        }
        stopRingtone();
        try {
            Ringtone r = RingtoneManager.getRingtone(
                    context.getApplicationContext(),
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE));
            if (r == null) {
                Log.w(TAG, "playRingtone: default ringtone unavailable");
                return;
            }
            r.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build());
            r.setLooping(true);
            r.play();
            ringtone = r;
        } catch (Throwable t) {
            Log.e(TAG, "playRingtone failed", t);
            ringtone = null;
        }
        startVibrate(context);
    }

    /** 停止铃声与振动（无铃声时 no-op） */
    public static void stopRingtone() {
        try {
            if (ringtone != null) {
                if (ringtone.isPlaying()) {
                    ringtone.stop();
                }
                ringtone = null;
            }
        } catch (Throwable t) {
            Log.w(TAG, "stopRingtone: " + t);
            ringtone = null;
        }
        stopVibrate();
    }

    private static void startVibrate(Context context) {
        try {
            Vibrator v = getVibrator(context);
            if (v == null || !v.hasVibrator()) {
                return;
            }
            v.vibrate(VibrationEffect.createWaveform(VIBRATE_PATTERN, 1));
            vibrator = v;
        } catch (Throwable t) {
            Log.e(TAG, "startVibrate failed", t);
            vibrator = null;
        }
    }

    private static void stopVibrate() {
        try {
            if (vibrator != null) {
                vibrator.cancel();
                vibrator = null;
            }
        } catch (Throwable t) {
            Log.w(TAG, "stopVibrate: " + t);
            vibrator = null;
        }
    }

    private static Vibrator getVibrator(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            VibratorManager vm = (VibratorManager) context.getApplicationContext()
                    .getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
            return vm != null ? vm.getDefaultVibrator() : null;
        }
        return (Vibrator) context.getApplicationContext()
                .getSystemService(Context.VIBRATOR_SERVICE);
    }

    /* ------------------------------------------------------------------ */
    /* 回铃音（呼出 Ringing 期）                                           */
    /* ------------------------------------------------------------------ */

    /* 回铃循环调度：单参 startTone(TONE_SUP_RINGTONE) 仅播约 2s 一声，
     * 长振铃会静音——按 4s 周期重触发直至 stopBackTone（对齐北美回铃
     * 2s 响 4s 歇的节奏近似） */
    private static final long BACK_TONE_PERIOD_MS = 4000;
    private static android.os.Handler backToneHandler;

    /**
     * 播放回铃音：TONE_SUP_RINGTONE（440+480Hz 标准回铃）循环播放
     * 直至 stopBackTone，通话音量流。
     */
    public static void playBackTone() {
        stopBackTone();
        try {
            ToneGenerator tg = new ToneGenerator(
                    android.media.AudioManager.STREAM_VOICE_CALL, 80);
            if (backToneHandler == null) {
                backToneHandler = new android.os.Handler(
                        android.os.Looper.getMainLooper());
            }
            tg.startTone(ToneGenerator.TONE_SUP_RINGTONE);
            backTone = tg;
            scheduleBackTone();
        } catch (Throwable t) {
            Log.e(TAG, "playBackTone failed", t);
            releaseBackTone();
        }
    }

    private static void scheduleBackTone() {
        final ToneGenerator tg = backTone;
        if (tg == null) {
            return;
        }
        backToneHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (backTone == tg) {
                    try {
                        tg.startTone(ToneGenerator.TONE_SUP_RINGTONE);
                        scheduleBackTone();
                    } catch (Throwable t) {
                        releaseBackTone();
                    }
                }
            }
        }, BACK_TONE_PERIOD_MS);
    }

    /** 停止回铃音（同步取消循环调度并释放 ToneGenerator） */
    public static void stopBackTone() {
        if (backToneHandler != null) {
            backToneHandler.removeCallbacksAndMessages(null);
        }
        releaseBackTone();
    }

    /** 释放 ToneGenerator（置 null 先于 release，防回调窗口重复释放） */
    private static void releaseBackTone() {
        try {
            ToneGenerator tg = backTone;
            backTone = null;
            if (tg != null) {
                tg.stopTone();
                tg.release();
            }
        } catch (Throwable t) {
            Log.w(TAG, "stopBackTone: " + t);
            backTone = null;
        }
    }

    /** 全部停止（会话终态兜底） */
    public static void stopAll() {
        stopRingtone();
        stopBackTone();
    }
}
