package com.novosdk.telecom;

/**
 * Telecom ConnectionService 基类（NovoSDK API 层，Acrobits 后端）。
 *
 * 直接继承真身：App 的 NovoConnectionService 经本类间接继承真身
 * ConnectionService（public abstract）——系统 Telecom 回调与真身
 * 连接管理体系直通（26 形态语义）。
 *
 * App 反射调用面（线上版 NovoConnectionService 经反射调真身私有方法；
 * 单源版反射目标为本类——本类把真身私有方法包装为 NovoSDK 类型公开
 * 于此，App 代码得以与线上逐字一致，仅类名差异）：
 * - extractWaitingCall(ConnectionRequest)：真身私有 → Optional&lt;NovoSDK CallEvent&gt;
 * - hasMaximumSelfManagedConnections()：真身私有直转
 * - updateState(ConnectionServiceNative$State)：真身私有静态，按枚举名映射
 */
public abstract class ConnectionService
        extends cz.acrobits.libsoftphone.telecom.ConnectionService {

    /**
     * 等待来电提取（App 反射调用面）。
     * 内部反射真身同名私有方法取真身事件，经 Bridge 包装为 NovoSDK 事件——
     * App 侧 as? CallEvent（NovoSDK 类型）直接成功。真身侧异常/无等待事件
     * 返回 empty（App 按 SDK 语义 return null 走 super 兜底）。
     */
    public java.util.Optional<com.novosdk.event.CallEvent> extractWaitingCall(
            android.telecom.ConnectionRequest request) {
        try {
            java.lang.reflect.Method m = cz.acrobits.libsoftphone.telecom.ConnectionService.class
                    .getDeclaredMethod("extractWaitingCall",
                            android.telecom.ConnectionRequest.class);
            m.setAccessible(true);
            Object result = m.invoke(this, request);
            if (result instanceof java.util.Optional) {
                Object ev = ((java.util.Optional<?>) result).orElse(null);
                if (ev instanceof cz.acrobits.libsoftphone.event.CallEvent) {
                    return java.util.Optional.ofNullable(
                            com.novosdk.Bridge.wrap(
                                    (cz.acrobits.libsoftphone.event.CallEvent) ev));
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.ConnectionService",
                    "extractWaitingCall bridge: " + t);
        }
        return java.util.Optional.empty();
    }

    /** self-managed 连接数上限（App 反射调用面；真身私有直转，异常按未满处理） */
    public boolean hasMaximumSelfManagedConnections() {
        try {
            java.lang.reflect.Method m = cz.acrobits.libsoftphone.telecom.ConnectionService.class
                    .getDeclaredMethod("hasMaximumSelfManagedConnections");
            m.setAccessible(true);
            return Boolean.TRUE.equals(m.invoke(this));
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Telecom 集成状态机推进（App 反射调用面；真身私有静态 updateState
     * 按枚举名映射转发——两侧 State 枚举同名值）。
     */
    public static void updateState(ConnectionServiceNative.State state) {
        if (state == null) {
            return;
        }
        try {
            Class<?> realStateClass = Class.forName(
                    "cz.acrobits.libsoftphone.telecom.ConnectionServiceNative$State");
            Object realState = null;
            for (Object c : realStateClass.getEnumConstants()) {
                if (((Enum<?>) c).name().equals(state.name())) {
                    realState = c;
                    break;
                }
            }
            if (realState == null) {
                return;
            }
            java.lang.reflect.Method m = cz.acrobits.libsoftphone.telecom.ConnectionService.class
                    .getDeclaredMethod("updateState", realStateClass);
            m.setAccessible(true);
            m.invoke(null, realState);
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.ConnectionService", "updateState bridge: " + t);
        }
    }
}
