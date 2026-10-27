package com.yeastar.sipcore;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;

/**
 * 通话会话注册表：多通话改造的核心容器（arch-design §3.3.1）。
 *
 * - 并发上限 {@link #MAX_SESSIONS}（2），终态会话不计容量（仅短暂
 *   留存供 UI 展示终态）；
 * - 键为会话内部 sessionId（呼出会话在 INVITE 提交前尚无 pjsua callId，
 *   callId 为 -1，故不能作键）；callId 检索经 {@link #findByCallId}；
 * - 终态会话在 {@link #TERMINAL_LINGER_MS} 后由 {@link #purgeExpired}
 *   移除（对齐"终态短暂可见后移除"节奏，detail-design §2.1）；
 * - 线程模型：写路径仅引擎主线程；公开方法 synchronized 以支持
 *   snapshotCalls"任意时刻可查"契约（跨线程读取容器安全，会话字段
 *   仍以主线程写入为准，读到的可能是近似值 —— 视图快照语义足够）。
 */
public class CallSessionRegistry {

    /** 最大并发通话数（超出创建失败；JS 拨号前已有拦截，此处双保险） */
    public static final int MAX_SESSIONS = 2;

    /** 终态会话在 callList 中的滞留时长（ms） */
    public static final long TERMINAL_LINGER_MS = 1500;

    /** 插入序保序（快照顺序稳定，UI 列表不跳动） */
    private final LinkedHashMap<Long, CallSession> sessions =
            new LinkedHashMap<Long, CallSession>();

    private long nextSessionId = 1;

    /** 创建会话；活动会话满（>= MAX_SESSIONS 且未终态）返回 null */
    public synchronized CallSession create(int direction) {
        if (activeCount() >= MAX_SESSIONS) {
            return null;
        }
        /* callId 复用防御：pjsua 会回收 id，新会话顶掉同 callId 旧残留 */
        long id = nextSessionId++;
        CallSession session = new CallSession(id, direction);
        session.createdAt = System.currentTimeMillis();
        sessions.put(id, session);
        return session;
    }

    /** 按 sessionId 取会话（引擎内部用） */
    public synchronized CallSession get(long sessionId) {
        return sessions.get(sessionId);
    }

    /** 按 pjsua callId 检索（callId 无效/-1 时返回 null） */
    public synchronized CallSession findByCallId(int callId) {
        if (callId < 0) {
            return null;
        }
        for (CallSession s : sessions.values()) {
            if (s.callId == callId) {
                return s;
            }
        }
        return null;
    }

    /** 移除会话（引擎已确保 pc 等资源先行释放） */
    public synchronized CallSession remove(long sessionId) {
        return sessions.remove(sessionId);
    }

    /** 全部会话（含终态滞留）快照：插入序副本，任意时刻可查 */
    public synchronized List<CallSession> snapshot() {
        return new ArrayList<CallSession>(sessions.values());
    }

    /** 会话总数（含终态滞留） */
    public synchronized int size() {
        return sessions.size();
    }

    /** 活动会话数（未终态，容量判定用） */
    public synchronized int activeCount() {
        int n = 0;
        for (CallSession s : sessions.values()) {
            if (!s.isTerminal()) {
                n++;
            }
        }
        return n;
    }

    /** 清空（shutdown 用，引擎已先行释放各会话资源） */
    public synchronized void clear() {
        sessions.clear();
    }

    /** 标记终态滞留到点：到 finalizeRemoveAt 的会话移除出 callList */
    public synchronized void purgeExpired(long nowMs) {
        Iterator<CallSession> it = sessions.values().iterator();
        while (it.hasNext()) {
            CallSession s = it.next();
            if (s.finalizeRemoveAt > 0 && nowMs >= s.finalizeRemoveAt) {
                it.remove();
            }
        }
    }
}
