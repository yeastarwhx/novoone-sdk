package com.novosdk.internal.service;

/**
 * 内部调用许可管理（NovoSDK softphone API 层）。
 *
 * App 使用面（NovoConnectionService）：
 * ElevationStateManager.getInstance()
 *     .allowBecause(ElevationStateManager.AllowlistReason.ConnectionServiceStarted)
 *
 * 真身为 SDK 内部跨进程调用鉴权白名单（按枚举名映射转发，见 allowBecause）。
 */
public final class ElevationStateManager {

    /** 许可来源 */
    public enum AllowlistReason {
        ConnectionServiceStarted,
        InCallServiceStarted,
        PushServiceStarted
    }

    private static final ElevationStateManager sInstance = new ElevationStateManager();

    private ElevationStateManager() {
    }

    public static ElevationStateManager getInstance() {
        return sInstance;
    }

    /**
     * 放开调用许可。真身有同名鉴权实现（javap 实证：枚举 FCMPush/
     * ConnectionServiceStarted/ExactAlarmArrived 等 + getInstance().allowBecause），
     * 按枚举名映射转发；无对应真身枚举值时仅记录（老工程直连时
     * App 侧仅使用 ConnectionServiceStarted，必然命中映射）。
     */
    public void allowBecause(AllowlistReason reason) {
        try {
            cz.acrobits.libsoftphone.internal.service.ElevationStateManager.AllowlistReason real =
                    cz.acrobits.libsoftphone.internal.service.ElevationStateManager
                            .AllowlistReason.valueOf(reason.name());
            cz.acrobits.libsoftphone.internal.service.ElevationStateManager.getInstance()
                    .allowBecause(real);
        } catch (IllegalArgumentException e) {
            android.util.Log.w("Novosdk.Elevation",
                    "allowBecause no real enum mapping: " + reason);
        }
    }

}
