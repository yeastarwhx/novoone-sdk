package cz.acrobits.libsoftphone.event;

/**
 * 消息事件（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：OnNewEvent 分支 instanceof 判断 + body 读取（Toast 展示）。
 */
public class MessageEvent extends Event {

    /** 消息体（可为 null） */
    public String body;
}
