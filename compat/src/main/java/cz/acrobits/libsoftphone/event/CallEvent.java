package cz.acrobits.libsoftphone.event;

import cz.acrobits.ali.Json;

/**
 * 通话事件（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * 身份模型：eventId = 引擎 CallSession.sessionId；SdkBridge 按该 id 把
 * 事件对象解析回引擎会话。transients 为随 eventId 存续的键值通道——
 * SDK 每次回调都 new 新的 CallEvent 包装，App 跨回调传递数据全部经
 * transients（push 来源标记 / requestId / callerIdName）。
 */
public class CallEvent extends Event {

    /** transients 固定键：拨号动作 */
    public static final class Transients {
        public static final String DIAL_ACTION = "dialAction";

        private Transients() {
        }
    }

    /** 账号下标（本引擎单账号，恒 0） */
    public int accountId;

    /** 首远端用户（App 直接字段访问：remoteUser?.displayName / ?.genericUri） */
    public RemoteUser remoteUser;

    /** 接通时间（未接通为 null；App：timeEstablished?.toMilliseconds()） */
    public TimePoint timeEstablished;

    /** 随事件存续的瞬态数据（永不抛 NPE 的读写通道） */
    /** fastjson 序列化/反序列化跳过此字段（Dict 类型 fastjson 无法自动往返，
     *  此前桥层反序列化即抛 ClassCastException 阻断所有 JS→Native 调用——
     *  挂断/静音/保持全部无效）。桥层只需 eventId 等简单字段定位通话，
     *  transients 仅在 Native 层内部使用 */
    @com.alibaba.fastjson.annotation.JSONField(serialize = false, deserialize = false)
    public Json.Dict transients = new Json.Dict();

    public CallEvent() {
    }

    public CallEvent(RemoteUser user) {
        if (user != null) {
            this.remoteUser = user;
            addRemoteUser(user);
        }
    }
}
