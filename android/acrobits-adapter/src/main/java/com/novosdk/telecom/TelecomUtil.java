package com.novosdk.telecom;

import android.content.ComponentName;
import android.content.Context;

import java.util.Optional;

/**
 * Telecom 集成工具（NovoSDK API 层，Acrobits 后端）。
 * App 消费面（isSelfManaged/registerCallingAccount）直通真身同名 API。
 */
public final class TelecomUtil {

    private TelecomUtil() {
    }

    public static boolean isSelfManaged(Context context, android.telecom.PhoneAccountHandle handle) {
        return cz.acrobits.libsoftphone.telecom.TelecomUtil.isSelfManaged(context, handle);
    }

    public static Optional<android.telecom.PhoneAccountHandle> registerCallingAccount(
            Context context, ComponentName connectionService, boolean selfManaged) {
        return cz.acrobits.libsoftphone.telecom.TelecomUtil.registerCallingAccount(
                context, connectionService, selfManaged);
    }
}
