package com.novosdk.telecom.compat;

import android.telecom.Connection;

import com.novosdk.event.CallEvent;

/**
 * API 26+ 层级（NovoSDK softphone API 层）：
 * 增加 self-managed 属性（系统不接管通话 UI）。
 */
class ConnectionImplApi26 extends ConnectionImplApi23 {

    ConnectionImplApi26(CallEvent callEvent, boolean selfManaged) {
        super(callEvent);
        if (selfManaged) {
            setConnectionProperties(getConnectionProperties()
                    | PROPERTY_SELF_MANAGED);
        }
    }
}
