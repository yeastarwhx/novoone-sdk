package com.novosdk;

/**
 * SDK 能力集（NovoSDK API 层，Acrobits 后端）。
 * 常量直通真身（features 为枚举数组，值形状对齐）。
 */
public final class SDK {

    /** 能力项 */
    public enum Feature {
        Provisioning
    }

    public static final Feature[] features = {Feature.Provisioning};

    /** 构建号（真身 build 号透出） */
    public static final String build = String.valueOf(cz.acrobits.libsoftphone.SDK.build);

    private SDK() {
    }
}
