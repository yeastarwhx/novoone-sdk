package com.novosdk.ali;

import java.util.Collection;

/**
 * 集合工具（NovoSDK API 层，Acrobits 后端）。
 *
 * 转发真身 cz.acrobits.commons.util.CollectionUtil（线上直连同源同行为）。
 * App 使用面：CollectionUtil.contains(SDK.features, SDK.Feature.Provisioning)。
 */
public final class CollectionUtil {

    private CollectionUtil() {
    }

    public static <T> boolean contains(T[] array, T value) {
        return cz.acrobits.commons.util.CollectionUtil.contains(array, value);
    }

    /** Collection 重载：NovoSDK 形状补充（真身仅数组版；App 当前未消费，兜底自有实现） */
    public static <T> boolean contains(Collection<T> collection, T value) {
        if (collection == null) {
            return false;
        }
        for (T item : collection) {
            if (item == null ? value == null : item.equals(value)) {
                return true;
            }
        }
        return false;
    }
}
