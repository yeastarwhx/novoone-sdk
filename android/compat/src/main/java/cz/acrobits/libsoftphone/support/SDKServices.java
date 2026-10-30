package cz.acrobits.libsoftphone.support;

import java.util.concurrent.ConcurrentHashMap;

/**
 * SDK 服务定位器（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：SDKServices.get(LocaleService.class) 取服务实例。
 * 本引擎无服务化子系统，注册的服务为 no-op 实现（类形态对齐，行为空）。
 */
public final class SDKServices {

    private static final ConcurrentHashMap<Class<?>, Object> SERVICES =
            new ConcurrentHashMap<Class<?>, Object>();

    static {
        SERVICES.put(cz.acrobits.libsoftphone.support.service.LocaleService.class,
                new cz.acrobits.libsoftphone.support.service.LocaleService());
    }

    private SDKServices() {
    }

    /** 按类型取服务（未注册返回 null——App 侧自行 try-catch 兜底） */
    @SuppressWarnings("unchecked")
    public static <T> T get(Class<T> type) {
        return (T) SERVICES.get(type);
    }
}
