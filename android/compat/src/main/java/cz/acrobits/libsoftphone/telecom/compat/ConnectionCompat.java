package cz.acrobits.libsoftphone.telecom.compat;

import android.os.Build;
import android.telecom.Connection;

import cz.acrobits.libsoftphone.event.CallEvent;
import cz.acrobits.libsoftphone.telecom.ConnectionService;

/**
 * Connection 兼容工厂（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：
 * - ConnectionCompat.createConnection(callEvent, selfManaged)（App 的
 *   NovoConnectionFactory 注释引用的分版逻辑，本类为对齐实现）
 * - ConnectionCompat.audioRouting(connection).setAudioRoutingCallback(service)
 *   （NovoConnectionService：把音频路由回调挂到所属 ConnectionService）
 *
 * 分版层级：Api35 &gt; Api34 &gt; Api26 &gt; Api23——低版本设备实例化高层级
 * 类可能命中高 API 方法（NoSuchMethodError），必须按系统版本选择。
 */
public final class ConnectionCompat {

    private ConnectionCompat() {
    }

    /** 按系统版本创建对应层级的 Connection 子类 */
    public static Connection createConnection(CallEvent callEvent, boolean selfManaged) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            return new ConnectionImplApi35(callEvent, selfManaged);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return new ConnectionImplApi34(callEvent, selfManaged);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return new ConnectionImplApi26(callEvent, selfManaged);
        } else {
            return new ConnectionImplApi23(callEvent);
        }
    }

    /** 音频路由句柄（路由事件挂到 ConnectionService，转 SDK 音频模块） */
    public static AudioRouting audioRouting(Connection connection) {
        return new AudioRoutingHandle(connection);
    }

    /**
     * 引擎状态 → Connection 回写（含本地 hold 映射：Established + hold →
     * setOnHold，能力位随状态维护）。
     */
    public static void applyCallState(Connection connection,
                                      cz.acrobits.libsoftphone.data.Call.State state,
                                      boolean held) {
        if (connection instanceof ConnectionImplApi23) {
            ((ConnectionImplApi23) connection).applyCallState(state, held);
        }
    }

    /** 音频路由回调注册面 */
    public interface AudioRouting {

        void setAudioRoutingCallback(ConnectionService service);
    }

    private static final class AudioRoutingHandle implements AudioRouting {

        private final Connection mConnection;

        AudioRoutingHandle(Connection connection) {
            mConnection = connection;
        }

        @Override
        public void setAudioRoutingCallback(ConnectionService service) {
            com.yeastar.sipcore.SdkBridge.get()
                    .bindAudioRoutingService(mConnection, service);
        }
    }
}
