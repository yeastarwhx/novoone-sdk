package com.yeastar.sipcore;

import android.util.Log;

/**
 * ys_pjsua_app (C) <-> Java 桥（移植自 novoone-sip-demo，包名改为
 * com.yeastar.sipcore）。
 *
 * native 入口 1:1 对齐 ys_pjsua_app.h；onXxx 静态方法由 C 侧
 * (pjsua worker 线程, AttachCurrentThread) 回调，本类不持状态，
 * 全部转发给 SipWebrtcEngine（由其切主线程）。
 *
 * 相对 demo 版差异：
 *   - 新增 nativeRejectCall（486 拒接）/ nativeSetOutgoingInviteHeaders
 *     （呼出 INVITE 附加头，一次性消费）/ nativeUnregisterAccount（登出）；
 *   - onIncomingSdp 追加 requestId / callerIdName 两个 INVITE 头参数
 *     （头缺失为 null；C 侧 NewStringUTF 已完成拷贝，Java String 生命周期安全）。
 *
 * 线程纪律（红线）：native 方法只能由 Java 线程串行先行调用
 * （首个调用完成 jclass 缓存，见 pjsip_jni.c ensure_init 注释），
 * 不得在 ys 回调线程（onXxx 落点）内回调 native。
 */
public final class JniBridge {

    private static final String TAG = "JniBridge";

    static {
        System.loadLibrary("pjsip_jni");
    }

    private JniBridge() {
    }

    /* ---------------- native 入口（C 实现：pjsip_jni.c） ---------------- */

    /** @return 0 成功，-1 失败（须在 nativeInitPjsua 之前调用） */
    public static native int nativeSetTransport(int transport);

    public static native void nativeSetUserAgent(String ua);

    /** @return 0 成功，-1 失败 */
    public static native int nativeInitPjsua(int sipPort);

    /** @return accId (>=0)，失败 -1 */
    public static native int nativeRegisterAccount(String server, String user,
                                                   String pass, String proxy,
                                                   String authUser,
                                                   String displayName,
                                                   int expires);

    /** 注销并删除账号。@return 0 成功，-1 失败 */
    public static native int nativeUnregisterAccount(int accId);

    /** 刷新注册（重发 REGISTER，不删账号、不影响进行中的通话）。
     *  推送唤醒场景账号在册时使用。@return 0 成功，-1 失败 */
    public static native int nativeReregisterAccount(int accId);

    /** @return callId (>=0)，失败 -1 */
    public static native int nativeMakeCall(int accId, String dest, String sdp);

    /** @return 0 成功，-1 失败 */
    public static native int nativeAnswerCall(int callId, int code, String sdp);

    /** 来电拒接（振铃期 486；呼出/通话中调用返回 -1）。@return 0 成功，-1 失败 */
    public static native int nativeRejectCall(int callId);

    /** 盲转（REFER）：dst 纯号码或完整 URI。@return 0 成功 */
    public static native int nativeXferCall(int callId, String dst);

    /** 咨询转（REFER+Replaces）：callId 对端 <-> destCallId 对端。@return 0 成功 */
    public static native int nativeXferReplaces(int callId, int destCallId);

    /**
     * 下一次呼出 INVITE 附加自定义头（"Name: Value\n" 多行，一次性
     * 消费：仅紧接着的第一次 nativeMakeCall 生效并被清除）。
     *
     * @param headers 头文本；null 仅清除
     * @return 0 成功，-1 失败
     */
    public static native int nativeSetOutgoingInviteHeaders(String headers);

    /** REGISTER 附加自定义头（粘性；null = 清除）。@return 0 成功 */
    public static native int nativeSetRegisterHeaders(String headers);

    /** 用新 offer SDP 发 re-INVITE（hold/resume）。@return 0 成功，-1 失败 */
    public static native int nativeReinviteCall(int callId, String sdp, String headers);

    /**
     * 通知库"本机网络已切换"，启动信令恢复（shutdown 死连接 + 账号
     * re-REGISTER + 通话 dialog 换 transport）。进度经 onIpChangeProgress
     * 回调，SHUTDOWN_TP 步完成后引擎发起媒体恢复（同凭据 re-INVITE）。
     *
     * @return 0 状态机已启动（非恢复完成），-1 失败
     */
    public static native int nativeHandleIpChange();

    /** @return 0 成功，-1 失败 */
    public static native int nativeHangup(int callId);

    public static native void nativeHangupAll();

    /** @return 0 成功，-1 失败 */
    public static native int nativeDestroy();

    /* ------------- C 回调落点（pjsua worker 线程 -> engine） ------------- */

    /** 注册状态变化：status 为 SIP 状态码 (200 成功)。 */
    static void onRegisterState(int accId, int status, String text) {
        SipWebrtcEngine.getInstance().postRegisterState(accId, status, text);
    }

    /** 呼叫状态变化：state 见 SipWebrtcEngine.CALL_STATE_*。 */
    static void onCallState(int callId, int state, int lastStatus) {
        SipWebrtcEngine.getInstance().postCallState(callId, state, lastStatus);
    }

    /** 呼出后 200 OK 携带的 answer SDP。 */
    static void onAnswerSdp(int callId, String sdp) {
        SipWebrtcEngine.getInstance().postAnswerSdp(callId, sdp);
    }

    /** REFER 转接进度（NOTIFY 状态码；final 2xx = 成功）。 */
    static void onTransferState(int callId, int status, int isFinal) {
        SipWebrtcEngine.getInstance().postTransferState(callId, status, isFinal);
    }

    /**
     * 来电 INVITE 携带的 offer SDP + 头 + 对端号码（手动接听链：引擎
     * 缓存 offer，等 callAnswer / callReject）。
     *
     * @param requestId     INVITE 头 X-Request-ID（缺失 null）
     * @param callerIdName  INVITE 头 X-Nov-Caller-ID-Name（缺失 null）
     * @param remoteNumber  From URI user 部分（对端号码，缺失 null）
     */
    static void onIncomingSdp(int callId, String sdp, String requestId,
                              String callerIdName, String remoteNumber) {
        SipWebrtcEngine.getInstance().postIncomingSdp(callId, sdp, requestId,
                callerIdName, remoteNumber);
    }

    /** re-INVITE SDP（hold/resume，复用 answer 链）。 */
    static void onReinviteSdp(int callId, String sdp) {
        SipWebrtcEngine.getInstance().postReinviteSdp(callId, sdp);
    }

    /** pjsua 日志：level 1=ERROR..5=TRACE。level<=4 进回调（4=SIP 消息
     *  dump，SDK 日志文件需要；5 级库层已不产生），全量转 logcat。 */
    static void onLog(int level, String msg) {
        if (msg == null || msg.isEmpty()) {
            return;
        }
        /* level 4 为 SIP 消息 dump（TX/RX），全量进 logcat 便于排障 */
        Log.d(TAG, "[pjsip" + level + "] " + msg);
        if (level <= 4) {
            SipWebrtcEngine.getInstance().postEngineLog(level, msg);
        }
    }

    /**
     * 网络切换恢复进度（nativeHandleIpChange 触发）。step 取
     * pjsua_ip_change_op 枚举值（pjsua.h）：IP_CHANGE_STEP_COMPLETED
     * （见 SipWebrtcEngine 常量）= 全部完成，引擎此时发起媒体恢复；
     * status 为该步结果（0 成功）。
     */
    static void onIpChangeProgress(int step, int status) {
        SipWebrtcEngine.getInstance().postIpChangeProgress(step, status);
    }

}
