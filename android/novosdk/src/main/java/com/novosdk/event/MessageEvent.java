package com.novosdk.event;

/**
 * 消息事件（NovoSDK softphone API 层）。
 *
 * App 使用面：OnNewEvent 分支 instanceof 判断 + body 读取（Toast 展示）。
 */
public class MessageEvent extends Event {

    /** 消息体（可为 null） */
    public String body;
}
