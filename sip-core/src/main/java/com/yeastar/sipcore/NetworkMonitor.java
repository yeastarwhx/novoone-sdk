package com.yeastar.sipcore;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;

import java.net.Inet4Address;

/**
 * 网络变化检测（网络切换恢复链的检测端，09-30-android-call-continuity）。
 *
 * 三分支换网判定（规格移植自 RN useNetworkRestoreSync，双端语义一致）：
 *   - lost-recovered：全部断网后恢复（断网窗口 TCP 已死，IP 同样必触发）
 *   - type-switch   ：WiFi &lt;-&gt; 蜂窝无缝切换（旧网未 Lost 新网先 Available）
 *   - ip-changed    ：WiFi -&gt; WiFi 本地 IP 变化（不同 AP；同 IP 换 SSID 不触发）
 *
 * 防抖：候选事件（onAvailable/onLost/onLinkPropertiesChanged）进入
 * STABLE_DELAY_MS 静默窗，窗口内新事件仅刷新计时——切换中间态与
 * 双网竞态（WiFi/蜂窝反复摇摆）合并为一次上报。
 *
 * 上报口径：当前活跃网络（getActiveNetwork）的 transport 类型 + IPv4
 * 本地地址构成 networkKey，与上次成功上报的 key 不同才触发。
 *
 * 线程：事件源为系统 binder 线程，防抖与判定全部收敛到主线程 Handler
 * （引擎线程纪律：会话操作仅主线程）；listener.onNetworkChanged 在
 * 主线程回调。
 */
class NetworkMonitor {

    interface Listener {
        /** 换网事件（已防抖、key 已变化）；reason 见三分支 */
        void onNetworkChanged(String reason);
    }

    /** 候选网络稳定窗：窗口内无新变化才上报 */
    static final long STABLE_DELAY_MS = 800;

    private static final String TYPE_WIFI = "wifi";
    private static final String TYPE_CELL = "cell";
    private static final String TYPE_OTHER = "other";

    private final ConnectivityManager cm;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Listener listener;

    /** 上次上报口径的网络标识 "type|ip"；null = 从未有效（全断网/未启动） */
    private String lastKey = null;
    private Runnable pendingCheck = null;
    private boolean registered = false;

    private final ConnectivityManager.NetworkCallback systemCallback =
            new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    scheduleStableCheck();
                }

                @Override
                public void onLost(Network network) {
                    /* 全部断网（活跃网络已空）：清 lastKey，恢复时必触发
                     * （断网窗口 NAT/TCP 连接已死，IP 不变也要恢复）；
                     * 无缝切换的旧网 Lost（活跃网络仍在）不处理，由
                     * onAvailable 的 key 对比覆盖 */
                    scheduleStableCheck();
                }

                @Override
                public void onLinkPropertiesChanged(Network network,
                                                    LinkProperties lp) {
                    /* IP 变化（WiFi->WiFi / 重获地址）走这里 */
                    scheduleStableCheck();
                }
            };

    NetworkMonitor(Context context, Listener listener) {
        this.cm = (ConnectivityManager) context.getApplicationContext()
                .getSystemService(Context.CONNECTIVITY_SERVICE);
        this.listener = listener;
    }

    /** 开始监听。以当前网络为基线（基线变化才上报，启动不误触发）。 */
    synchronized void start() {
        if (cm == null || registered) {
            return;
        }
        lastKey = currentKey();
        try {
            cm.registerDefaultNetworkCallback(systemCallback, main);
            registered = true;
        } catch (Exception e) {
            /* 极少数 ROM 限制：无网络监听（恢复链只剩库内被动检测兜底） */
        }
    }

    synchronized void stop() {
        if (!registered) {
            return;
        }
        registered = false;
        try {
            cm.unregisterNetworkCallback(systemCallback);
        } catch (Exception ignored) {
        }
        if (pendingCheck != null) {
            main.removeCallbacks(pendingCheck);
            pendingCheck = null;
        }
    }

    /** 候选事件进入防抖窗（窗口内新事件刷新计时，静默后判定一次） */
    private synchronized void scheduleStableCheck() {
        if (pendingCheck == null) {
            pendingCheck = new Runnable() {
                @Override
                public void run() {
                    pendingCheck = null;
                    checkNow();
                }
            };
        }
        main.removeCallbacks(pendingCheck);
        main.postDelayed(pendingCheck, STABLE_DELAY_MS);
    }

    /** 防抖静默后的最终判定（主线程） */
    private synchronized void checkNow() {
        String key = currentKey();
        if (key == null) {
            /* 无可用网络：清基线（恢复时必触发），不上报 */
            lastKey = null;
            return;
        }
        if (key.equals(lastKey)) {
            return;
        }
        String reason = lastKey == null
                ? "lost-recovered"
                : deriveReason(lastKey, key);
        lastKey = key;
        listener.onNetworkChanged(reason);
    }

    /** 当前活跃网络 "type|ip"（无网/信息缺失返回 null） */
    private String currentKey() {
        if (cm == null) {
            return null;
        }
        Network active = cm.getActiveNetwork();
        if (active == null) {
            return null;
        }
        NetworkCapabilities caps = cm.getNetworkCapabilities(active);
        LinkProperties lp = cm.getLinkProperties(active);
        if (caps == null || lp == null) {
            return null;
        }
        String type;
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            type = TYPE_WIFI;
        } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            type = TYPE_CELL;
        } else {
            type = TYPE_OTHER; /* VPN 等：类型变化同样触发（恢复幂等） */
        }
        String ip = null;
        for (LinkAddress addr : lp.getLinkAddresses()) {
            if (addr.getAddress() instanceof Inet4Address) {
                ip = addr.getAddress().getHostAddress();
                break;
            }
        }
        return type + "|" + (ip != null ? ip : "no-ip");
    }

    /** 从基线 key 与新 key 推导触发原因（三分支的后两支） */
    private static String deriveReason(String oldKey, String newKey) {
        String oldType = oldKey.substring(0, oldKey.indexOf('|'));
        String newType = newKey.substring(0, newKey.indexOf('|'));
        if (!oldType.equals(newType)) {
            return "type-switch:" + oldType + "->" + newType;
        }
        return "ip-changed"; /* 同类型（WiFi->WiFi）IP 变化 */
    }
}
