package com.novosdk.event.history;

/**
 * 事件流查询（NovoSDK softphone API 层）。
 */
public final class StreamQuery {

    private StreamQuery() {
    }

    /** 传统通话历史流 key */
    public static String legacyCallHistoryStreamKey() {
        return "legacyCallHistory";
    }
}
