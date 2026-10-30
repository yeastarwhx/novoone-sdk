package cz.acrobits.libsoftphone.event.history;

/**
 * 事件流查询（Acrobits libSoftPhone SDK 兼容门面）。
 */
public final class StreamQuery {

    private StreamQuery() {
    }

    /** 传统通话历史流 key */
    public static String legacyCallHistoryStreamKey() {
        return "legacyCallHistory";
    }
}
