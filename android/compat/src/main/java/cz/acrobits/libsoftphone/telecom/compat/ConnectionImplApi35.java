package cz.acrobits.libsoftphone.telecom.compat;

import cz.acrobits.libsoftphone.event.CallEvent;

/**
 * API 35+ 层级（Acrobits libSoftPhone SDK 兼容门面）。
 * 仅作版本分层锚点（不触碰 API 35 CallEndpoint 族方法，避免低版本
 * NoSuchMethodError 风险面扩大）。
 */
class ConnectionImplApi35 extends ConnectionImplApi34 {

    ConnectionImplApi35(CallEvent callEvent, boolean selfManaged) {
        super(callEvent, selfManaged);
    }
}
