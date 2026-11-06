package com.novosdk.telecom.compat;

/**
 * API 34+ 层级（真身直系继承，见 ConnectionImplApi23 架构说明）。
 */
class ConnectionImplApi34 extends
        cz.acrobits.libsoftphone.telecom.compat.RealConnectionBridge.Api34 {

    ConnectionImplApi34(com.novosdk.event.CallEvent callEvent, boolean selfManaged) {
        super(com.novosdk.Bridge.unwrap(callEvent), selfManaged);
    }
}
