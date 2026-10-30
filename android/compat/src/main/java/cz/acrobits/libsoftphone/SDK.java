package cz.acrobits.libsoftphone;

/**
 * SDK 能力集（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：CollectionUtil.contains(SDK.features, SDK.Feature.Provisioning)
 * 决定是否解析 provisioning.xml。
 */
public final class SDK {

    /** 启用的能力集（保留 Provisioning 形态：provisioning 解析为空实现） */
    public static final Feature[] features = {Feature.Provisioning};

    /** SDK 构建号（App 注释代码引用过，保留形态） */
    public static final String build = "compat";

    private SDK() {
    }

    public enum Feature {
        Provisioning,
        Video,
        Telephony
    }
}
