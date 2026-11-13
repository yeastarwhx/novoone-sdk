package com.novosdk.telecom;

import android.content.ComponentName;
import android.content.Context;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;

import java.util.Optional;

/**
 * Telecom 集成工具（NovoSDK softphone API 层）。
 *
 * App 使用面：
 * - TelecomUtil.registerCallingAccount(context, component, selfManaged)
 *   → Optional&lt;PhoneAccountHandle&gt;（NovoServices.configureConnectionService）
 * - TelecomUtil.isSelfManaged(context, handle)（NovoConnectionService）
 */
public final class TelecomUtil {

    private static final String TAG = "Novosdk.TelecomUtil";

    /* 主线程写（App 启动注册）/ Telecom binder 线程读（来电上报链），volatile 保证可见性 */
    private static volatile PhoneAccountHandle sRegisteredHandle;

    private TelecomUtil() {
    }

    /**
     * 注册通话 PhoneAccount（App 包内 ConnectionService）。
     *
     * @param selfManaged true 时附加 highlightColor；无论取值均注册为
     *                    self-managed（系统不接管通话 UI、App 自绘——
     *                    本引擎唯一形态，见 isSelfManaged）
     * @return 注册成功的 PhoneAccountHandle；Telecom 不可用/失败返回 empty
     */
    public static Optional<PhoneAccountHandle> registerCallingAccount(
            Context ctx, ComponentName component, boolean selfManaged) {
        try {
            TelecomManager tm = ctx.getSystemService(TelecomManager.class);
            if (tm == null) {
                return Optional.empty();
            }
            PhoneAccountHandle handle = new PhoneAccountHandle(component, "NovoCalls");
            int capabilities = PhoneAccount.CAPABILITY_SELF_MANAGED
                    | PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING;
            PhoneAccount.Builder builder = new PhoneAccount.Builder(handle, "Novo Calls")
                    .setCapabilities(capabilities);
            if (selfManaged) {
                builder.setHighlightColor(0xFF2E7D32);
            }
            tm.registerPhoneAccount(builder.build());
            sRegisteredHandle = handle;
            android.util.Log.i(TAG, "PhoneAccount registered: " + component
                    + " (selfManaged=" + selfManaged + ")");
            return Optional.of(handle);
        } catch (Throwable t) {
            android.util.Log.w(TAG, "registerCallingAccount failed: " + t);
            return Optional.empty();
        }
    }

    /** 已注册的通话账号句柄（未注册返回 null；来电上报 Telecom 用）。
     *  静态变量进程重启后为 null（系统侧 PhoneAccount 仍在），回退到
     *  TelecomManager 查找本包的已注册账号 */
    public static PhoneAccountHandle registeredHandle() {
        if (sRegisteredHandle != null) {
            return sRegisteredHandle;
        }
        try {
            Context ctx = com.novosdk.ali.AndroidUtil.getApplicationContext();
            if (ctx == null) {
                return null;
            }
            TelecomManager tm = ctx.getSystemService(TelecomManager.class);
            if (tm == null) {
                return null;
            }
            for (PhoneAccountHandle h : tm.getCallCapablePhoneAccounts()) {
                if (h != null && h.getComponentName() != null
                        && ctx.getPackageName().equals(
                            h.getComponentName().getPackageName())) {
                    sRegisteredHandle = h;
                    android.util.Log.i(TAG, "registeredHandle: found existing " + h);
                    return h;
                }
            }
        } catch (Throwable t) {
            android.util.Log.w(TAG, "registeredHandle fallback failed: " + t);
        }
        return null;
    }

    /** 该 PhoneAccount 是否 self-managed（本实现注册即 self-managed） */
    public static boolean isSelfManaged(Context ctx, PhoneAccountHandle handle) {
        if (handle == null) {
            return false;
        }
        try {
            PhoneAccount account = ctx.getSystemService(TelecomManager.class)
                    .getPhoneAccount(handle);
            return account != null
                    && (account.getCapabilities() & PhoneAccount.CAPABILITY_SELF_MANAGED) != 0;
        } catch (Throwable t) {
            return sRegisteredHandle != null && sRegisteredHandle.equals(handle);
        }
    }
}
