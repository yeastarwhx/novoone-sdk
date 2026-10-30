package com.yeastar.sipcore;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

/**
 * 音频路由读写（AudioManager 实现，静态工具类）。
 *
 * 字符串协议（对齐 detail-design §5 / arch-design §3.2）：
 *   "Receiver" | "Speaker" | "BluetoothSCO" | "Headset"
 *
 * 设备类型映射对齐 novoone-app（AudioRouteModule / 旧 MainApplication）：
 *   BluetoothSCO <- TYPE_BLUETOOTH_SCO / TYPE_BLUETOOTH_A2DP / TYPE_BLE_HEADSET
 *                   / TYPE_BLE_SPEAKER / TYPE_HEARING_AID
 *   Headset      <- TYPE_WIRED_HEADSET / TYPE_WIRED_HEADPHONES
 *                   / TYPE_USB_HEADSET / TYPE_USB_DEVICE
 *   （A2DP 不支持双向语音，按现状仅归并到蓝牙组列出，不单独成路由）
 *
 * 版本策略：API 31+ 用 setCommunicationDevice（availableCommunicationDevices
 * 枚举）；低版本退 setSpeakerphoneOn / startBluetoothSco（经典行为）。
 *
 * 线程模型：方法无内部状态，任意线程可调（AudioManager 线程安全）；
 * 引擎门面在主线程调用。
 */
public final class AudioRouteHelper {

    private static final String TAG = "AudioRouteHelper";

    public static final String ROUTE_RECEIVER = "Receiver";
    public static final String ROUTE_SPEAKER = "Speaker";
    public static final String ROUTE_BLUETOOTH_SCO = "BluetoothSCO";
    public static final String ROUTE_HEADSET = "Headset";

    private AudioRouteHelper() {
    }

    /** 路由信息（type 为字符串协议值；本机听筒/扬声器 deviceName 为空串） */
    public static final class RouteInfo {
        public final String type;
        public final String deviceName;

        public RouteInfo(String type, String deviceName) {
            this.type = type;
            this.deviceName = deviceName != null ? deviceName : "";
        }

        @Override
        public String toString() {
            return type + (deviceName.isEmpty() ? "" : " (" + deviceName + ")");
        }
    }

    /* ------------------------------------------------------------------ */
    /* 查询                                                                */
    /* ------------------------------------------------------------------ */

    /** 当前通话路由 */
    public static RouteInfo getCurrent(Context context) {
        AudioManager am = audioManager(context);
        if (am == null) {
            return new RouteInfo(ROUTE_RECEIVER, "");
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AudioDeviceInfo selected = am.getCommunicationDevice();
            if (selected != null) {
                String route = deviceTypeToRoute(selected.getType());
                if (route != null) {
                    return new RouteInfo(route, deviceLabel(selected));
                }
            }
            /* 未显式选定：按连接状态推导（有线/蓝牙优先于听筒） */
            return new RouteInfo(defaultConnectedRoute(am), "");
        }
        if (am.isBluetoothScoOn()) {
            return new RouteInfo(ROUTE_BLUETOOTH_SCO, "");
        }
        if (am.isSpeakerphoneOn()) {
            return new RouteInfo(ROUTE_SPEAKER, "");
        }
        return new RouteInfo(defaultConnectedRoute(am), "");
    }

    /** 可选路由列表（固定序：Receiver / Speaker / BluetoothSCO / Headset；
     * Receiver 与 Speaker 恒在（基础路由），蓝牙/有线按实际连接列出。
     * 契约 audioExternal = available.size() > 2（§2.2） */
    public static List<RouteInfo> getAvailable(Context context) {
        List<RouteInfo> list = new ArrayList<RouteInfo>();
        list.add(new RouteInfo(ROUTE_RECEIVER, ""));
        list.add(new RouteInfo(ROUTE_SPEAKER, ""));
        AudioManager am = audioManager(context);
        if (am == null) {
            return list;
        }
        AudioDeviceInfo[] devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        boolean bt = false;
        String btName = "";
        boolean wired = false;
        String wiredName = "";
        for (AudioDeviceInfo d : devices) {
            String route = deviceTypeToRoute(d.getType());
            if (ROUTE_BLUETOOTH_SCO.equals(route) && !bt) {
                bt = true;
                btName = deviceLabel(d);
            } else if (ROUTE_HEADSET.equals(route) && !wired) {
                wired = true;
                wiredName = deviceLabel(d);
            }
        }
        if (bt) {
            list.add(new RouteInfo(ROUTE_BLUETOOTH_SCO, btName));
        }
        if (wired) {
            list.add(new RouteInfo(ROUTE_HEADSET, wiredName));
        }
        return list;
    }

    /* ------------------------------------------------------------------ */
    /* 设置                                                                */
    /* ------------------------------------------------------------------ */

    /**
     * 进入通话音频模式（通话建立时调用）：设置 MODE_IN_COMMUNICATION，
     * 使 VOICE_COMMUNICATION 录音源按通话策略路由/增益。缺此设置时
     * 听筒模式发送人声极小（三星真机实测结论：切换扬声器触发的
     * setRoute 内 setMode 才会恢复）。
     */
    public static void beginCommunicationMode(Context context) {
        AudioManager am = audioManager(context);
        if (am == null) {
            return;
        }
        if (am.getMode() != AudioManager.MODE_IN_COMMUNICATION) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            Log.i(TAG, "audio mode -> IN_COMMUNICATION");
        }
    }

    /**
     * 通话建立时的初始路由决策（有线 > 蓝牙 > 听筒），显式设置。
     *
     * 背景（三星真机实测）：部分 OEM 在 Telecom 感知到通话后，会由
     * 系统 BluetoothInCallService 自动激活 HFP SCO（耳机出声），但
     * AudioManager 侧无任何记录（getCommunicationDevice 为空），UI 查询
     * 推导出听筒——显示与实际脱节。此处 App 主动决策并显式设置，
     * 使「实际路由 / 系统账本 / UI 显示」三者一致，路由主权保持在 App。
     * 仅在「从无通话进入首通」时调用（引擎侧判重），不打扰通话中
     * 用户已手动选择的路由。
     *
     * @return 实际生效的路由（ROUTE_*）
     */
    public static String applyInitialRoute(Context context) {
        AudioManager am = audioManager(context);
        if (am == null) {
            return ROUTE_RECEIVER;
        }
        String route = ROUTE_RECEIVER;
        AudioDeviceInfo[] devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        for (AudioDeviceInfo d : devices) {
            String r = deviceTypeToRoute(d.getType());
            if (ROUTE_HEADSET.equals(r)) {
                route = ROUTE_HEADSET;
                break;
            }
            if (ROUTE_BLUETOOTH_SCO.equals(r)) {
                route = ROUTE_BLUETOOTH_SCO;
            }
        }
        /* 显式设置（失败不回退强制听筒：保持系统默认，由 getCurrent 的
         * SCO 实际激活检测兜底显示） */
        boolean ok = setRoute(context, route);
        Log.i(TAG, "initial route -> " + route + " ok=" + ok);
        return route;
    }

    /** 退出通话音频模式（通话全部结束时调用） */
    public static void endCommunicationMode(Context context) {
        AudioManager am = audioManager(context);
        if (am == null) {
            return;
        }
        if (am.getMode() != AudioManager.MODE_NORMAL) {
            am.setMode(AudioManager.MODE_NORMAL);
            Log.i(TAG, "audio mode -> NORMAL");
        }
    }

    /**
     * 切换通话路由。
     *
     * @param type 字符串协议路由（ROUTE_*）
     * @return true 切换指令已下发；false 目标不可用/失败（调用方回退当前
     *         路由并提示，对齐异常矩阵"蓝牙 SCO 连接失败"行为）
     */
    @SuppressWarnings("deprecation")
    public static boolean setRoute(Context context, String type) {
        AudioManager am = audioManager(context);
        if (am == null) {
            return false;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return setRouteApi31(am, type);
        }

        /* 低版本：经典开关组合（对齐 novoone-app legacy 行为） */
        if (ROUTE_SPEAKER.equals(type)) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            am.stopBluetoothSco();
            am.setBluetoothScoOn(false);
            am.setSpeakerphoneOn(true);
            Log.i(TAG, "route -> Speaker (legacy)");
            return true;
        }
        if (ROUTE_BLUETOOTH_SCO.equals(type)) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            am.setSpeakerphoneOn(false);
            am.startBluetoothSco();
            am.setBluetoothScoOn(true);
            Log.i(TAG, "route -> BluetoothSCO (legacy)");
            return true;
        }
        if (ROUTE_HEADSET.equals(type)) {
            /* 有线耳机：清除显式覆盖，交系统自动路由 */
            am.setSpeakerphoneOn(false);
            am.stopBluetoothSco();
            am.setBluetoothScoOn(false);
            Log.i(TAG, "route -> Headset (legacy, system auto)");
            return true;
        }
        if (ROUTE_RECEIVER.equals(type)) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            am.stopBluetoothSco();
            am.setBluetoothScoOn(false);
            am.setSpeakerphoneOn(false);
            Log.i(TAG, "route -> Receiver (legacy)");
            return true;
        }
        Log.w(TAG, "setRoute: unknown route " + type);
        return false;
    }

    private static boolean setRouteApi31(AudioManager am, String type) {
        int[] targetTypes = routeToTargetTypes(type);
        if (targetTypes == null) {
            Log.w(TAG, "setRoute: unknown route " + type);
            return false;
        }
        List<AudioDeviceInfo> candidates = am.getAvailableCommunicationDevices();
        AudioDeviceInfo target = null;
        for (AudioDeviceInfo d : candidates) {
            for (int t : targetTypes) {
                if (d.getType() == t) {
                    target = d;
                    break;
                }
            }
            if (target != null) {
                break;
            }
        }
        if (target == null) {
            Log.w(TAG, "setRoute: device not found for " + type
                    + ", available=" + candidates.size());
            return false;
        }
        if (am.getMode() != AudioManager.MODE_IN_COMMUNICATION) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
        }
        boolean ok = am.setCommunicationDevice(target);
        Log.i(TAG, "setCommunicationDevice type=" + target.getType()
                + " ok=" + ok);
        return ok;
    }

    /* ------------------------------------------------------------------ */
    /* 类型映射                                                            */
    /* ------------------------------------------------------------------ */

    /** AudioDeviceInfo.type -> 路由字符串；未识别返回 null */
    private static String deviceTypeToRoute(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return ROUTE_RECEIVER;
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return ROUTE_SPEAKER;
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
            case AudioDeviceInfo.TYPE_BLE_HEADSET:
            case AudioDeviceInfo.TYPE_BLE_SPEAKER:
            case AudioDeviceInfo.TYPE_HEARING_AID:
                return ROUTE_BLUETOOTH_SCO;
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
            case AudioDeviceInfo.TYPE_USB_HEADSET:
            case AudioDeviceInfo.TYPE_USB_DEVICE:
                return ROUTE_HEADSET;
            default:
                return null;
        }
    }

    /** 路由字符串 -> 候选设备类型（对齐 novoone-app 的分组） */
    private static int[] routeToTargetTypes(String route) {
        if (ROUTE_SPEAKER.equals(route)) {
            return new int[]{AudioDeviceInfo.TYPE_BUILTIN_SPEAKER};
        }
        if (ROUTE_RECEIVER.equals(route)) {
            return new int[]{AudioDeviceInfo.TYPE_BUILTIN_EARPIECE};
        }
        if (ROUTE_BLUETOOTH_SCO.equals(route)) {
            return new int[]{
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER,
                    AudioDeviceInfo.TYPE_HEARING_AID,
            };
        }
        if (ROUTE_HEADSET.equals(route)) {
            return new int[]{
                    AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    AudioDeviceInfo.TYPE_USB_HEADSET,
                    AudioDeviceInfo.TYPE_USB_DEVICE,
            };
        }
        return null;
    }

    /**
     * 未显式选定路由时的默认推导：有线 > 蓝牙（SCO 实际激活时）> 听筒。
     * 蓝牙分支不限版本：isBluetoothScoOn 反映 SCO 音频链路的实际激活
     * 状态，OEM 侧自动激活（见 applyInitialRoute 注释）同样为 true，
     * 据此兜底显示。
     */
    @SuppressWarnings("deprecation")
    private static String defaultConnectedRoute(AudioManager am) {
        AudioDeviceInfo[] devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        boolean wired = false;
        boolean bt = false;
        for (AudioDeviceInfo d : devices) {
            String route = deviceTypeToRoute(d.getType());
            if (ROUTE_HEADSET.equals(route)) {
                wired = true;
            } else if (ROUTE_BLUETOOTH_SCO.equals(route)) {
                bt = true;
            }
        }
        if (wired) {
            return ROUTE_HEADSET;
        }
        if (bt && am.isBluetoothScoOn()) {
            return ROUTE_BLUETOOTH_SCO;
        }
        return ROUTE_RECEIVER;
    }

    private static String deviceLabel(AudioDeviceInfo d) {
        CharSequence product = d.getProductName();
        if (product != null && product.length() > 0) {
            return product.toString();
        }
        return "";
    }

    private static AudioManager audioManager(Context context) {
        if (context == null) {
            return null;
        }
        Context ctx = context.getApplicationContext();
        return (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
    }
}
