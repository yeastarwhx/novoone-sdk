package cz.acrobits.commons.util;

import java.util.Collection;

/**
 * 集合工具（Acrobits SDK 兼容门面）。
 *
 * App 使用面：CollectionUtil.contains(SDK.features, SDK.Feature.Provisioning)。
 */
public final class CollectionUtil {

    private CollectionUtil() {
    }

    public static <T> boolean contains(T[] array, T value) {
        if (array == null) {
            return false;
        }
        for (T item : array) {
            if (item == null ? value == null : item.equals(value)) {
                return true;
            }
        }
        return false;
    }

    public static <T> boolean contains(Collection<T> collection, T value) {
        return collection != null && collection.contains(value);
    }
}
