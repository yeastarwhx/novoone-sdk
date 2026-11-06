package com.novosdk.telecom.compat;

/**
 * API 26+ 层级（真身直系继承，见 ConnectionImplApi23 架构说明）。
 */
class ConnectionImplApi26 extends
        cz.acrobits.libsoftphone.telecom.compat.RealConnectionBridge.Api26 {

    ConnectionImplApi26(com.novosdk.event.CallEvent callEvent, boolean selfManaged) {
        super(com.novosdk.Bridge.unwrap(callEvent), selfManaged);
    }
}
