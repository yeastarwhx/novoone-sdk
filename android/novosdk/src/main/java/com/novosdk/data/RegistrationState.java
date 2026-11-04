package com.novosdk.data;

/**
 * 注册状态（NovoSDK softphone API 层）。
 *
 * App 依赖 name 做状态映射（SdkAccountEventListener.mapSdkStateToMvi），
 * 枚举名不可改；label 提供可读标签。
 */
public enum RegistrationState {
    Registered("Registered"),
    Registering("Registering"),
    NotRegistered("Not registered"),
    RegistrationFailed("Registration failed");

    /** 本地化/可读标签 */
    public final String label;

    RegistrationState(String label) {
        this.label = label;
    }
}
