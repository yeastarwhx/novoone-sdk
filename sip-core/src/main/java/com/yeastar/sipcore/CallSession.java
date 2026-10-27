package com.yeastar.sipcore;

import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.PeerConnection;

/**
 * 单路通话会话：demo 版 SipWebrtcEngine 的单通话引擎字段全部下沉至此
 * （会话化改造，见 arch-design §3.3.1）。
 *
 * 线程模型：所有字段仅在主线程读写（引擎 Handler 收敛 + Registry 同为
 * 主线程对象），因此用公开可变字段而非同步访问器——delegate 层同样
 * 必须在主线程读取（快照消费方经 SdkThreadExecutor.executeOnMain）。
 *
 * 视图状态（callStateView，detail-design §2.1 映射，由引擎写入）：
 *   呼出：Trying → Ringing → Established → Terminated/Busy/Error/Unauthorized
 *   来电：IncomingTrying → IncomingRinging →（接听）IncomingAnswered
 *                                        →（拒接）IncomingRejected
 *                                        →（对端取消）IncomingMissed
 */
public class CallSession {

    /* 方向（首事件定型，不随重协商变） */
    public static final int DIRECTION_OUT = 0;
    public static final int DIRECTION_IN = 1;

    /* 视图状态常量（对齐 JS 层 CallState 子集） */
    public static final String STATE_TRYING = "Trying";
    public static final String STATE_RINGING = "Ringing";
    public static final String STATE_ESTABLISHED = "Established";
    public static final String STATE_TERMINATED = "Terminated";
    public static final String STATE_BUSY = "Busy";
    public static final String STATE_ERROR = "Error";
    public static final String STATE_UNAUTHORIZED = "Unauthorized";
    public static final String STATE_INCOMING_TRYING = "IncomingTrying";
    public static final String STATE_INCOMING_RINGING = "IncomingRinging";
    public static final String STATE_INCOMING_ANSWERED = "IncomingAnswered";
    public static final String STATE_INCOMING_REJECTED = "IncomingRejected";
    public static final String STATE_INCOMING_MISSED = "IncomingMissed";

    /* 会话注册表内部键（创建即分配，与 pjsua callId 解耦：
     * 呼出会话在 INVITE 提交前尚无 callId） */
    final long sessionId;

    /* ---------------- 标识 ---------------- */
    /** pjsua call id（呼出会话在 INVITE 提交前为 -1） */
    public int callId = -1;
    /** 会议组 shim：groupId = String(callId)，Call.id = "group_" + callId */
    public String groupId;
    /** 方向：DIRECTION_IN / DIRECTION_OUT（创建时锚定） */
    public final int direction;
    /** 对端 URI user 部分（呼出=被叫号码；来电=主叫号码） */
    public String remoteNumber;
    /** 账号显示名（From display，缺省回退 remoteNumber） */
    public String accountName;

    /* ---------------- 头缓存 ---------------- */
    /** 来电：INVITE X-Request-ID 头；呼出：我方注入的 requestId */
    public String requestId;
    /** 来电：INVITE X-Nov-Caller-ID-Name 头（接通后仍可读） */
    public String callerIdName;

    /* ---------------- 状态 ---------------- */
    /** 最新 ys_pjsip_inv_state（SipWebrtcEngine.CALL_STATE_*） */
    public int pjsuaState;
    /** 最后 SIP 响应码（180/200/486/...） */
    public int lastStatus;
    /** 视图状态（STATE_*，引擎按 detail-design §2.1 写入） */
    public String callStateView = STATE_TRYING;

    /* ---------------- hold / mute ---------------- */
    /** 本端主动 hold（track 静音 + recvonly 方向 re-INVITE） */
    public boolean holdFlag;
    /** 对端 hold（收到的 offer 方向非 sendrecv，如 sendonly） */
    public boolean remoteHoldFlag;
    /** 本端静音（track.setEnabled(false)，不发 re-INVITE） */
    public boolean muteFlag;

    /* ---------------- 来电手动接听 ---------------- */
    /** 来电 INVITE offer 缓存（callAnswer 时消费） */
    public String offerSdp;
    /** 已调 callAnswer（canBeAnswered 翻 false，防重复接听） */
    public boolean answerRequested;
    /** 已调 callReject（终态归 IncomingRejected 的判据） */
    public boolean rejectRequested;

    /* ---------------- WebRTC（引擎主线程访问） ---------------- */
    public PeerConnection pc;
    public AudioSource audioSource;
    public AudioTrack audioTrack;

    /* ---------------- offer/answer 状态机（demo ivar 下沉） ---------------- */
    /** caller: INVITE already sent */
    public boolean inviteSent;
    /** callee/re-INVITE: 本地 answer 已 set，等 ICE 候选发 200 */
    public boolean answerPending;
    /** callee/re-INVITE: 200 已发 */
    public boolean answerSent;
    /** 呼入初始应答零候选保护：首次观测到零候选的时刻（0=未触发；
     *  超预算仍零候选则 486 拒接，见 SipWebrtcEngine.sendAnswerWithLocalSdp） */
    public long zeroCandidateSince;
    /** 本地 offer（INVITE/re-INVITE）已发出，等对端 200 answer 应用 */
    public boolean awaitingAnswer;
    /** hold/resume: 本地 offer 已 set，等 ICE 候选发 re-INVITE */
    public boolean reinvitePending;

    /* ---------------- 时间戳（SystemClock/毫秒由引擎写入） ---------------- */
    /** 会话创建时间 */
    public long createdAt;
    /** CONFIRMED 时间（callStartTime 契约字段） */
    public long callStartTime;
    /** 最近一次 hold 生效时间（holdStartTime 契约字段） */
    public long holdStartTime;
    /** 进入终态时间（0 = 未终态） */
    public long terminatedAt;
    /** 终态延迟清除时间（Registry 到点移除出 callList） */
    public long finalizeRemoveAt;

    /* ---------------- ICE gathering 看门狗（引擎主线程 Runnable） ---------------- */
    Runnable gatherWatchdog;

    CallSession(long sessionId, int direction) {
        this.sessionId = sessionId;
        this.direction = direction;
    }

    /** 是否终态（Registry 判定 linger/容量用） */
    public boolean isTerminal() {
        return STATE_TERMINATED.equals(callStateView)
                || STATE_BUSY.equals(callStateView)
                || STATE_ERROR.equals(callStateView)
                || STATE_UNAUTHORIZED.equals(callStateView)
                || STATE_INCOMING_REJECTED.equals(callStateView)
                || STATE_INCOMING_MISSED.equals(callStateView);
    }

    /** 是否呼入方向 */
    public boolean isIncoming() {
        return direction == DIRECTION_IN;
    }

    /** canBeAnswered 契约：IncomingRinging 且尚未接听/超时（§2.2） */
    public boolean canBeAnswered() {
        return isIncoming()
                && STATE_INCOMING_RINGING.equals(callStateView)
                && !answerRequested
                && offerSdp != null;
    }

    /** isOnHold 契约（§2.2）：本端或对端 hold 均置位（视图展示语义） */
    public boolean isOnHold() {
        return holdFlag || remoteHoldFlag;
    }

    @Override
    public String toString() {
        return "CallSession{callId=" + callId
                + ", dir=" + (isIncoming() ? "in" : "out")
                + ", view=" + callStateView
                + ", pjsua=" + pjsuaState
                + ", last=" + lastStatus
                + (remoteNumber != null ? ", num=" + remoteNumber : "")
                + (requestId != null ? ", reqId=" + requestId : "")
                + "}";
    }
}
