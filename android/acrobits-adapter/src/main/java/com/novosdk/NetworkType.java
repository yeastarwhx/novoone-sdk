package com.novosdk;

/**
 * 网络类型（NovoSDK softphone API 层）。
 *
 * App 使用面：Listeners.OnNetworkChangeDetected 回调参数（仅日志打印）。
 */
public enum NetworkType {
    NONE,
    WIFI,
    MOBILE,
    ETHERNET,
    BLUETOOTH,
    VPN,
    UNKNOWN
}
