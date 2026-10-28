package cz.acrobits.libsoftphone.telecom.compat;

import android.telecom.CallAudioState;
import android.telecom.Connection;
import android.telecom.DisconnectCause;

import com.yeastar.sipcore.SdkBridge;

import cz.acrobits.libsoftphone.Instance;
import cz.acrobits.libsoftphone.data.Call;
import cz.acrobits.libsoftphone.event.CallEvent;

/**
 * Connection 基础层级（API 23+，Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 的 NovoConnectionApiXX 子类（同包）覆盖 onSilence 拦截系统静音；
 * 其余系统通话控制回调转发 Instance.Calls.*（接听/拒接/挂断/保持）。
 * 状态回写（setRinging/setActive/setOnHold/setDisconnected）由 SdkBridge
 * 引擎回调驱动（applyCallState，幂等推进）。
 *
 * 09-21-android-telecom 移植项：
 * - 声明 CAPABILITY_SUPPORT_HOLD（系统让路策略）：不声明时 Telecom 接听
 *   蜂窝通话会按 ANSWER_DROPS_FG 直接丢弃本通话（三星实测根因）；声明后
 *   系统改调 onHold 让路，真正的 hold 业务仍由应用层承担
 * - 状态对齐幂等（appliedState 门：相同目标不重复设置/打日志）
 * - hold 状态映射（Established + holdFlag → STATE_HOLDING，能力位随状态
 *   维护；能力位唯一维护点 = alignState 分支——setConnectionCapabilities
 *   是整体赋值覆盖非按位或）
 * - onCallAudioStateChanged 转发 SdkBridge（系统侧路由事实 → UI 刷新，
 *   取代固定延时轮询——SCO 慢切换场景轮询会读到旧值）
 */
/* 包私有：App 侧 NovoConnectionFactory 同包扩展（对齐 Acrobits 可见性） */
class ConnectionImplApi23 extends Connection {

    protected final CallEvent callEvent;

    /** 已对齐的 Telecom 状态（幂等门：相同目标不重复设置） */
    private int appliedState = Connection.STATE_NEW;

    ConnectionImplApi23(CallEvent callEvent) {
        this.callEvent = callEvent;
        setAudioModeIsVoip(true);
        // 声明可被系统 hold（让路策略），见类注释
        setConnectionCapabilities(Connection.CAPABILITY_SUPPORT_HOLD);
        SdkBridge.get().registerTelecomConnection(callEvent != null ? callEvent.getEventId() : 0, this);
    }

    /* ---------------- 系统通话控制 → SDK ---------------- */

    @Override
    public void onAnswer() {
        try {
            Instance.Calls.answerIncoming(callEvent, Call.DesiredMedia.voiceOnly());
            /* 耳机接听无 UI 路径：App 不在前台时主动前台化（09-21 移植——
             * 冷启动场景麦克风采集受限 + 通话页不在前台）*/
            SdkBridge.get().bringAppToFront();
        } catch (Throwable t) {
            android.util.Log.e("Acrobits.TelecomConn", "onAnswer 异常: " + t);
        }
    }

    @Override
    public void onReject() {
        try {
            Instance.Calls.rejectIncomingHere(callEvent,
                    new Call.RejectReason("Rejected via Telecom", Call.RejectReason.Type.User));
        } catch (Throwable t) {
            android.util.Log.e("Acrobits.TelecomConn", "onReject 异常: " + t);
        }
    }

    /**
     * 挂断（含三星先斩后奏防御——09-21 移植）：
     * 蜂窝来电期间系统无视 CAPABILITY_SUPPORT_HOLD，先 markCallAsDisconnected
     * 再回调本方法（先斩后奏）终结 VoIP 通话。判定特征 = 连接已被系统置
     * DISCONNECTED（正常耳机挂断时系统不会预先标记）；蜂窝 managed call
     * 存在作复合条件。命中即系统策略终结：不挂引擎通话（引擎侧保持，
     * 交 SystemCallHoldController 承接），仅清理本连接。
     */
    @Override
    public void onDisconnect() {
        try {
            if (getState() == Connection.STATE_DISCONNECTED
                    && SdkBridge.get().isManagedCellularCallActive()) {
                android.util.Log.i("Acrobits.TelecomConn",
                        "onDisconnect 系统策略终结（蜂窝通话存在），引擎通话保持"
                        + " eventId=" + (callEvent != null ? callEvent.getEventId() : null));
                disconnectAndDestroy(new DisconnectCause(DisconnectCause.REMOTE));
                return;
            }
            Instance.Calls.close(callEvent);
        } catch (Throwable t) {
            android.util.Log.e("Acrobits.TelecomConn", "onDisconnect 异常: " + t);
        }
    }

    @Override
    public void onHold() {
        Instance.Calls.setHeld(callEvent, true);
    }

    @Override
    public void onUnhold() {
        Instance.Calls.setHeld(callEvent, false);
    }

    /** 音量键静音：Acrobits 默认转为忽略来电（IncomingIgnored 终态）；
     *  App 子类覆盖本方法且不调 super 以保留来电。 */
    @Override
    public void onSilence() {
        SdkBridge.get().ignoreIncoming(callEvent);
    }

    /**
     * 系统侧路由事实回调（观察）：Telecom AudioRouteStateMachine 切换结果
     * （含 setAudioRoute 驱动的切换与系统自动变化，如蓝牙断开回落）。
     * 变化即转发 SdkBridge 驱动 UI 刷新；显示侧拉取经
     * SdkBridge.currentSystemAudioRoute()。
     */
    @Override
    public void onCallAudioStateChanged(CallAudioState state) {
        SdkBridge.get().onSystemAudioRouteChanged(state);
    }

    /* ---------------- 状态回写（SdkBridge 引擎回调驱动） ---------------- */

    /** 兼容入口（无 hold 信息时使用；held = false） */
    void applyCallState(Call.State state) {
        applyCallState(state, false);
    }

    /**
     * 状态回写（含本地 hold 映射；remoteHold 是对端行为，系统侧不体现）。
     */
    void applyCallState(Call.State state, boolean held) {
        if (state == null) {
            return;
        }
        switch (state) {
            case Trying:
            case Ringing:
                alignState(Connection.STATE_DIALING);
                break;
            case IncomingTrying:
            case IncomingRinging:
                alignState(Connection.STATE_RINGING);
                break;
            case Established:
            case IncomingAnswered:
                alignState(held ? Connection.STATE_HOLDING : Connection.STATE_ACTIVE);
                break;
            case IncomingIgnored:
                disconnectAndDestroy(new DisconnectCause(DisconnectCause.CANCELED));
                break;
            case IncomingRejected:
                disconnectAndDestroy(new DisconnectCause(DisconnectCause.REJECTED));
                break;
            case IncomingMissed:
                disconnectAndDestroy(new DisconnectCause(DisconnectCause.MISSED));
                break;
            default:
                disconnectAndDestroy(new DisconnectCause(DisconnectCause.LOCAL));
                break;
        }
    }

    /**
     * 幂等状态对齐：目标与当前一致时跳过（相同目标不重复 binder 调用）。
     * hold 能力位随状态维护（处于 hold 时加 CAPABILITY_HOLD，供系统侧
     * "恢复"语义识别）。
     */
    private void alignState(int target) {
        if (appliedState == target) {
            return;
        }
        android.util.Log.i("Acrobits.TelecomConn", "map "
                + Connection.stateToString(appliedState) + " -> "
                + Connection.stateToString(target) + " eventId="
                + (callEvent != null ? callEvent.getEventId() : null));
        appliedState = target;
        switch (target) {
            case Connection.STATE_ACTIVE:
                setActive();
                setConnectionCapabilities(Connection.CAPABILITY_SUPPORT_HOLD);
                break;
            case Connection.STATE_HOLDING:
                setOnHold();
                setConnectionCapabilities(
                        Connection.CAPABILITY_SUPPORT_HOLD | Connection.CAPABILITY_HOLD);
                break;
            case Connection.STATE_RINGING:
                setRinging();
                break;
            case Connection.STATE_DIALING:
                setDialing();
                break;
            default:
                break;
        }
    }

    /** 终态拆除（幂等门内推进，避免终态事件重复到达时二次 destroy） */
    private void disconnectAndDestroy(DisconnectCause cause) {
        if (appliedState == Connection.STATE_DISCONNECTED) {
            return;
        }
        appliedState = Connection.STATE_DISCONNECTED;
        setDisconnected(cause);
        destroy();
    }
}
