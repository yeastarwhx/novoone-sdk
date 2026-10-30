package cz.acrobits.libsoftphone.telecom;

/**
 * ConnectionService 原生状态机（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：仅反射访问（Class.forName("...ConnectionServiceNative$State")
 * + enumConstants 按 name 取值，随后反射调用 ConnectionService.updateState）。
 * State 常量名不可改动（App 反射匹配 "CreatingIncomingConnection"）。
 */
final class ConnectionServiceNative {

    private ConnectionServiceNative() {
    }

    /** Telecom 集成状态机状态 */
    enum State {
        Idle,
        CreatingIncomingConnection,
        ReportingIncomingCall,
        Error
    }
}
