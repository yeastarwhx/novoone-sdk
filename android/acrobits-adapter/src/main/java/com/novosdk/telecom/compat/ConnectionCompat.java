package com.novosdk.telecom.compat;

import android.telecom.Connection;

import com.novosdk.event.CallEvent;

/**
 * Telecom Connection 兼容工厂（NovoSDK API 层，Acrobits 后端）。
 *
 * createConnection 委托真身同名静态（真身 ConnectionApi extends
 * NativeConnection extends android.telecom.Connection，直返无包装）。
 * App 侧 NovoConnectionFactory 在此之上做 onSilence 拦截子类。
 */
public final class ConnectionCompat {

    private ConnectionCompat() {
    }

    public static Connection createConnection(CallEvent callEvent, boolean selfManaged) {
        return cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat.createConnection(
                com.novosdk.Bridge.unwrap(callEvent), selfManaged);
    }


    /**
     * 音频路由句柄（NovoSDK 形状，参数为 NovoSDK ConnectionService）。
     * 真身 audioRouting(connection) 为 ConnectionAudioRouting 接口强转——
     * 本家族经 ConnectionApi 已获得该身份，转发注册（service 运行时为
     * 真身 ConnectionService 子类，同时实现真身 Callback，强转安全）。
     * App 侧路由 UI 刷新仍以 ObserverBridge 的 onAudioRouteChanged 分发
     * 为主通道（S3 真机实证）；此注册对齐真身 Telecom 集成层行为。
     */
    public static AudioRouting audioRouting(Connection connection) {
        if (connection instanceof cz.acrobits.libsoftphone.telecom.ConnectionAudioRouting) {
            final cz.acrobits.libsoftphone.telecom.ConnectionAudioRouting real =
                    (cz.acrobits.libsoftphone.telecom.ConnectionAudioRouting) connection;
            return new AudioRouting() {
                @Override
                public void setAudioRoutingCallback(com.novosdk.telecom.ConnectionService service) {
                    if (service
                            instanceof cz.acrobits.libsoftphone.telecom.ConnectionAudioRouting.Callback) {
                        real.setAudioRoutingCallback(
                                (cz.acrobits.libsoftphone.telecom.ConnectionAudioRouting.Callback) service);
                    }
                }
            };
        }
        return new AudioRoutingHandle();
    }

    /** 音频路由回调注册面（NovoSDK 形状，对齐 :novosdk） */
    public interface AudioRouting {

        void setAudioRoutingCallback(com.novosdk.telecom.ConnectionService service);
    }

    private static final class AudioRoutingHandle implements AudioRouting {

        @Override
        public void setAudioRoutingCallback(com.novosdk.telecom.ConnectionService service) {
            // 骨架空实现（见 audioRouting 注释）
        }
    }
}
