package cz.acrobits.libsoftphone.internal.service;

/**
 * 内部调用许可管理（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面（NovoConnectionService）：
 * ElevationStateManager.getInstance()
 *     .allowBecause(ElevationStateManager.AllowlistReason.ConnectionServiceStarted)
 *
 * 原语义为 SDK 内部跨进程调用鉴权白名单；本实现无内部服务边界，恒放行。
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

    /** 放开调用许可（no-op：无内部鉴权边界） */
    public void allowBecause(AllowlistReason reason) {
        android.util.Log.d("Acrobits.Elevation", "allowBecause " + reason);
    }

}
