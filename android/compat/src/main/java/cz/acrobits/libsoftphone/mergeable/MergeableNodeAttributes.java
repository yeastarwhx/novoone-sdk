package cz.acrobits.libsoftphone.mergeable;

/**
 * 可合并节点属性（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：AccountXml 构造 / mergeValue 的属性参数
 * （MergeableNodeAttributes.gui()）。本实现为形态占位（值合并语义由
 * AccountXml 的 childValue 覆写承担）。
 */
public final class MergeableNodeAttributes {

    private final String mSource;

    private MergeableNodeAttributes(String source) {
        mSource = source;
    }

    /** GUI 来源属性 */
    public static MergeableNodeAttributes gui() {
        return new MergeableNodeAttributes("gui");
    }

    /** 服务器下发来源属性 */
    public static MergeableNodeAttributes server() {
        return new MergeableNodeAttributes("server");
    }

    @Override
    public String toString() {
        return "MergeableNodeAttributes{" + mSource + "}";
    }
}
