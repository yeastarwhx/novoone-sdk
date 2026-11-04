package com.novosdk.telecom.compat;

import com.novosdk.event.CallEvent;

/**
 * API 34+ 层级（NovoSDK softphone API 层）。
 * 与 Api26 行为一致，仅作版本分层锚点（对齐 Acrobits 分版工厂）。
 */
class ConnectionImplApi34 extends ConnectionImplApi26 {

    ConnectionImplApi34(CallEvent callEvent, boolean selfManaged) {
        super(callEvent, selfManaged);
    }
}
