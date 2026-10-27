package cz.acrobits.libsoftphone.event;

/**
 * 事件流（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：EventStream.load(StreamQuery.legacyCallHistoryStreamKey())。
 * 本实现无持久化事件流，load 返回共享实例（仅作 API 形态占位）。
 */
public class EventStream {

    private static final EventStream sLegacyCallHistory = new EventStream("legacyCallHistory");

    private final String mKey;

    private EventStream(String key) {
        mKey = key;
    }

    /** 加载事件流（key 对应流不存在时返回 null——本实现恒返回占位实例） */
    public static EventStream load(String key) {
        return sLegacyCallHistory;
    }

    public String getKey() {
        return mKey;
    }
}
