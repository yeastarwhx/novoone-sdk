package com.novosdk.telecom.compat;

import android.os.Build;
import android.telecom.Connection;

import com.novosdk.event.CallEvent;
import com.novosdk.telecom.ConnectionService;

/**
 * Connection 兼容工厂（NovoSDK softphone API 层）。
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

    /** 分版档位（pickLevel 单一来源；低版本设备实例化高层级类会命中高
     * API 方法抛 NoSuchMethodError，分档判断全工程仅此处一份——
     * NovoConnectionFactory 门面共用，未来加档只改这里） */
    static final int LEVEL_API23 = 23;
    static final int LEVEL_API26 = 26;
    static final int LEVEL_API34 = 34;
    static final int LEVEL_API35 = 35;

    private ConnectionCompat() {
    }

    /** 按系统版本返回分版档位（纯函数，sdkInt 参数注入便于单测） */
    static int pickLevel(int sdkInt) {
        if (sdkInt >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            return LEVEL_API35;
        } else if (sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return LEVEL_API34;
        } else if (sdkInt >= Build.VERSION_CODES.O) {
            return LEVEL_API26;
        } else {
            return LEVEL_API23;
        }
    }

    /**
     * 按系统版本创建对应层级的 Connection 子类。委托
     * {@link NovoConnectionFactory#create}（全工程唯一实例化 switch——
     * 创建的连接统一带 onSilence 拦截链：App 注册钩子时走钩子，
     * 未注册回退 SDK 默认停铃声，与 App 直连工厂的连接行为一致）。
     */
    public static Connection createConnection(CallEvent callEvent, boolean selfManaged) {
        return NovoConnectionFactory.create(callEvent, selfManaged);
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
                                      com.novosdk.data.Call.State state,
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
