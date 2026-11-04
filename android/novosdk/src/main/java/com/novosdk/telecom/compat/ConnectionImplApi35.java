package com.novosdk.telecom.compat;

import com.novosdk.event.CallEvent;

/**
 * API 35+ 层级（NovoSDK softphone API 层）。
 * 仅作版本分层锚点（不触碰 API 35 CallEndpoint 族方法，避免低版本
 * NoSuchMethodError 风险面扩大）。
 */
class ConnectionImplApi35 extends ConnectionImplApi34 {

    ConnectionImplApi35(CallEvent callEvent, boolean selfManaged) {
        super(callEvent, selfManaged);
    }
}
