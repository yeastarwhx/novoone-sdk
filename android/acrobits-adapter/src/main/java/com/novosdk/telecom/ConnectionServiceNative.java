package com.novosdk.telecom;

/**
 * ConnectionService 原生状态机（NovoSDK softphone API 层）。
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
