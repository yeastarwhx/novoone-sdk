package com.yeastar.sipcore;

/**
 * 引擎对外回调接口（delegate 层实现，Step 3 装配到 SdkDataSource）。
 *
 * 线程契约：全部回调均在主线程触发（引擎内部 Handler 收敛，ys 回调
 * 来自 pjsua worker 线程、SdpObserver 来自 WebRTC 内部线程，均先 post）。
 * 实现方不得在回调里直接调 native / 阻塞操作（红线）。
 */
public interface EngineCallback {

    /**
     * 任意会话状态/字段变化（pjsua 状态、视图状态、hold/mute、
     * 头缓存等）。上层据此刷新快照（RefreshCallViews → NativeCall 事件）。
     */
    void onCallSessionChanged(CallSession session);

    /**
     * 注册状态变化：status 为 SIP 状态码（200 成功），text 为状态文本。
     * 上层更新注册常驻通知。
     */
    void onRegisterState(int status, String text);

    /**
     * 新来电（INVITE 到达，offer 与头已缓存，视图状态 IncomingTrying）。
     * 上层负责展示仲裁（前台弹屏 / 后台横条）与铃声控制，接听/拒接
     * 经 callAnswer / callReject 发起。
     */
    void onIncomingCall(CallSession session);

    /**
     * 引擎日志：level 对齐 pjsua（1=ERROR..5=TRACE）。引擎已过滤为
     * level<=3 的关键日志，全量日志走 logcat。
     */
    void onLog(int level, String msg);

    /**
     * 网络切换事件（防抖后，reason 为 "类型|IP" 形态，如 "wifi|10.0.0.2"）。
     * 引擎内部已同时触发信令+媒体恢复链，本回调供上层做业务标记
     * （如换网 re-INVITE 的自定义头注入）。
     */
    void onNetworkChanged(String reason);
}
