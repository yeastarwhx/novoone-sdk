package cz.acrobits.libsoftphone.telecom;

import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.PhoneAccountHandle;

import com.yeastar.sipcore.CallSession;
import com.yeastar.sipcore.SdkBridge;

import java.util.Optional;

import cz.acrobits.libsoftphone.event.CallEvent;

/**
 * 系统通话 ConnectionService 基类（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 的 NovoConnectionService 继承本类，并对齐 SDK 原版流程覆盖
 * onCreateIncomingConnection；SDK 私有步骤经反射调用，方法签名与本类
 * 声明必须逐字匹配：
 * <pre>
 *   getDeclaredMethod("extractWaitingCall", ConnectionRequest.class)   → private 实例
 *   getDeclaredMethod("hasMaximumSelfManagedConnections")              → private 实例无参
 *   getDeclaredMethod("updateState", ConnectionServiceNative$State)    → private static
 * </pre>
 */
public abstract class ConnectionService extends android.telecom.ConnectionService {

    private static final String TAG = "Acrobits.ConnectionService";

    @Override
    public void onCreate() {
        super.onCreate();
    }

    /**
     * 默认来电连接创建（App 覆盖失败时的 super 回退路径）：
     * 取等待中的来电事件 → self-managed 满员检查 → 分版 Connection。
     */
    @Override
    public Connection onCreateIncomingConnection(
            PhoneAccountHandle connectionManagerPhoneAccount, ConnectionRequest request) {
        android.util.Log.i(TAG, "onCreateIncomingConnection called, extras="
                + request.getExtras());
        /* App 层的 createIncomingConnectionInternal 可能已先经反射消费了
         * pending 槽（extractWaitingCall），此处不依赖槽——直接从 extras
         * eventId 查找会话构造事件（不消费槽） */
        long eventId = request.getExtras() != null
                ? request.getExtras().getLong(
                    SdkBridge.EXTRA_EVENT_ID, -1) : -1;
        if (eventId > 0) {
            CallSession session = SdkBridge.get().findSession(eventId);
            if (session != null) {
                CallEvent event = SdkBridge.get().wrapEvent(session);
                Connection connection = cz.acrobits.libsoftphone.telecom.compat
                        .ConnectionCompat.createConnection(event, true);
                cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                        .audioRouting(connection).setAudioRoutingCallback(this);
                /* 存入连接表（BT 挂断/路由协同的核心） */
                SdkBridge.get().registerTelecomConnection(eventId, connection);
                android.util.Log.i(TAG, "Connection created for eventId=" + eventId);
                return connection;
            }
        }
        /* 兜底：原 pending 槽路径（App 层未消费时） */
        Optional<CallEvent> waiting = extractWaitingCall(request);
        if (!waiting.isPresent()) {
            return super.onCreateIncomingConnection(connectionManagerPhoneAccount, request);
        }
        if (hasMaximumSelfManagedConnections()) {
            return super.onCreateIncomingConnection(connectionManagerPhoneAccount, request);
        }
        boolean selfManaged = cz.acrobits.libsoftphone.telecom.TelecomUtil.isSelfManaged(
                this, connectionManagerPhoneAccount);
        Connection connection = cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                .createConnection(waiting.get(), selfManaged);
        cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                .audioRouting(connection).setAudioRoutingCallback(this);
        return connection;
    }

    /**
     * 去电连接创建（placeCall 触发）：与来电同构——取等待事件 → 满员检查 →
     * 分版 Connection。BT 挂断/路由协同依赖此 Connection。
     */
    @Override
    public Connection onCreateOutgoingConnection(
            PhoneAccountHandle connectionManagerPhoneAccount, ConnectionRequest request) {
        Optional<CallEvent> waiting = extractWaitingCall(request);
        if (!waiting.isPresent()) {
            return super.onCreateOutgoingConnection(connectionManagerPhoneAccount, request);
        }
        if (hasMaximumSelfManagedConnections()) {
            return super.onCreateOutgoingConnection(connectionManagerPhoneAccount, request);
        }
        boolean selfManaged = cz.acrobits.libsoftphone.telecom.TelecomUtil.isSelfManaged(
                this, connectionManagerPhoneAccount);
        Connection connection = cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                .createConnection(waiting.get(), selfManaged);
        cz.acrobits.libsoftphone.telecom.compat.ConnectionCompat
                .audioRouting(connection).setAudioRoutingCallback(this);
        return connection;
    }

    /* ---------------- 反射目标（签名不可改动） ---------------- */

    /**
     * 从 ConnectionRequest 提取等待上报的来电事件。
     * 上报链：SdkBridge.onIncomingCall → TelecomManager.addNewIncomingCall
     * （extras 携带事件 id）→ 系统回调本服务 → 此处取回事件。
     */
    private Optional<CallEvent> extractWaitingCall(ConnectionRequest request) {
        return SdkBridge.get().extractWaitingCall(request);
    }

    /** self-managed 同时只允许一路连接（对齐 Acrobits 行为） */
    private boolean hasMaximumSelfManagedConnections() {
        return SdkBridge.get().hasMaximumSelfManagedConnections();
    }

    /** Telecom 集成状态机推进（本实现无状态机，仅日志） */
    private static void updateState(ConnectionServiceNative.State state) {
        android.util.Log.d(TAG, "updateState -> " + state);
    }
}
