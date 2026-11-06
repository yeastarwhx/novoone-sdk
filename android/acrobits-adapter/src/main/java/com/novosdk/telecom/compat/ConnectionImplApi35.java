package com.novosdk.telecom.compat;

/**
 * API 35+ 层级（真身直系继承，见 ConnectionImplApi23 架构说明）。
 */
class ConnectionImplApi35 extends
        cz.acrobits.libsoftphone.telecom.compat.RealConnectionBridge.Api35 {

    ConnectionImplApi35(com.novosdk.event.CallEvent callEvent, boolean selfManaged) {
        super(com.novosdk.Bridge.unwrap(callEvent), selfManaged);
    }
}
