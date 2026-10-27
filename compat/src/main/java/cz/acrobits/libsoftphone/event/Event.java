package cz.acrobits.libsoftphone.event;

import java.util.ArrayList;
import java.util.List;

/**
 * 事件基类（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：setStream / setDirection / setAttribute / addRemoteUser /
 * setAccount（拨号组事件构建）、getEventId / getRemoteUser(int) /
 * getStorageStatus（日志）。
 */
public class Event {

    /** fastjson 序列化需要无参构造 */
    public Event() {
    }

    /** 事件方向 */
    public enum Direction {
        OUTGOING, INCOMING
    }

    /** GUI 属性集（App 仅用 GUI） */
    public enum Attributes {
        GUI
    }

    private long mEventId;
    private Direction mDirection;
    private final List<RemoteUser> mRemoteUsers = new ArrayList<RemoteUser>();
    private String mAccount;

    /** 事件唯一 ID（引擎会话 sessionId；未绑定会话为 0） */
    public long getEventId() {
        return mEventId;
    }

    /** SDK 内部绑定（Events.post 分配引擎会话 id 时） */
    public void setEventId(long eventId) {
        mEventId = eventId;
    }

    /** 存储状态（日志用；本实现无持久化事件流，返回 null） */
    public Object getStorageStatus() {
        return null;
    }

    /** 索引取远端用户（越界/未设置返回 null——App 侧可空消费） */
    public RemoteUser getRemoteUser(int index) {
        if (index < 0 || index >= mRemoteUsers.size()) {
            return null;
        }
        return mRemoteUsers.get(index);
    }

    public void addRemoteUser(RemoteUser user) {
        if (user != null) {
            mRemoteUsers.add(user);
        }
    }

    public void setAccount(String accountId) {
        mAccount = accountId;
    }

    public String getAccount() {
        return mAccount;
    }

    public void setDirection(Direction dir) {
        mDirection = dir;
    }

    public Direction getDirection() {
        return mDirection;
    }

    /** GUI 属性记录（无运行语义，仅保留调用面） */
    public void setAttribute(Attributes attr, String value) {
    }

    /** 事件流绑定（本实现无持久化流，容忍 null） */
    public void setStream(EventStream stream) {
    }
}
