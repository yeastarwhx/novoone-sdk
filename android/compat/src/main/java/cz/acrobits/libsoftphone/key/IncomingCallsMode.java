package cz.acrobits.libsoftphone.key;

/**
 * 来电模式（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：Instance.preferences.incomingCallsMode.set(STANDARD / PUSH)。
 * 本引擎来电统一走标准 SIP 注册（长连接），PUSH 仅作偏好记录——推送唤醒
 * 由宿主 FCM → Instance.Notifications.Push.handle 完成 re-REGISTER。
 */
public enum IncomingCallsMode {
    STANDARD, PUSH
}
