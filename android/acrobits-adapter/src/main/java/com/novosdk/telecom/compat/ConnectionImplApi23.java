package com.novosdk.telecom.compat;

import com.novosdk.event.CallEvent;

/**
 * Telecom Connection 分版基类 API23+（NovoSDK API 层，Acrobits 后端）。
 *
 * 真身直系继承（经 {@link cz.acrobits.libsoftphone.telecom.compat.RealConnectionBridge}，
 * 构造器透传不添加任何行为）：真身全套 Telecom 行为（onAnswer/onReject/
 * onHold/onDisconnect/DTMF 回调链、getAudioType、CallEndpoint 通知、与
 * 真身 AudioRouteManager 的路由协作）原样生效——与老工程（上线版）行为
 * 完全一致。onSilence 拦截由 App 侧 NovoConnectionApiXX 最顶层 override
 * 提供（与老工程同构）。
 *
 * 演进记录：S2 初版为 extends 真身 NativeConnection 骨架 + 手工复刻行为，
 * 因真身隐性依赖面（getAudioType 非空契约、路由管理器策略选择等）逐层
 * 踩坑（2026-11-06 Telecom 矩阵实证崩溃与扬声器失效），改为本直系架构。
 */
class ConnectionImplApi23 extends
        cz.acrobits.libsoftphone.telecom.compat.RealConnectionBridge.Api23 {

    ConnectionImplApi23(CallEvent callEvent) {
        super(com.novosdk.Bridge.unwrap(callEvent));
    }
}
