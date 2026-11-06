package cz.acrobits.libsoftphone.telecom.compat;

/**
 * 真身连接直系桥（Acrobits 后端，运行于真身包内）。
 *
 * 为什么在真身包：真身 ConnectionImplApi23/26/34/35 为 package-private，
 * 仅同包可继承——老工程（上线版）的 onSilence 拦截正是经同包子类实现
 * （NovoConnectionFactory 注释："以 Java 放入 SDK 同包"）。S1 包名改造
 * 时该架构被替换为自研复刻家族，行为与真身存在逐层偏差（2026-11-06
 * Telecom 矩阵实证：getAudioType 空指针崩溃、路由管理器策略降级致扬声器
 * 切换失效）。
 *
 * 本桥恢复线上原架构：直系继承真身连接（构造器透传，**不添加任何行为**），
 * 真身全套 Telecom 行为（onAnswer/onReject/onHold/onDisconnect/onDtmf/
 * getAudioType/CallEndpoint 通知/与真身 AudioRouteManager 的协作）原样
 * 生效。onSilence 拦截由 App 层 NovoConnectionApiXX（经 com.novosdk 家族
 * 继承本桥）在最顶层 override 提供——与老工程同构。
 */
public final class RealConnectionBridge {

    private RealConnectionBridge() {
    }

    /** API 26 以下层级（构造器无 selfManaged 参数） */
    public static class Api23 extends ConnectionImplApi23 {

        public Api23(cz.acrobits.libsoftphone.event.CallEvent event) {
            super(event);
        }
    }

    /** API 26+ 层级 */
    public static class Api26 extends ConnectionImplApi26 {

        public Api26(cz.acrobits.libsoftphone.event.CallEvent event, boolean selfManaged) {
            super(event, selfManaged);
        }
    }

    /** API 34+ 层级 */
    public static class Api34 extends ConnectionImplApi34 {

        public Api34(cz.acrobits.libsoftphone.event.CallEvent event, boolean selfManaged) {
            super(event, selfManaged);
        }
    }

    /** API 35+ 层级 */
    public static class Api35 extends ConnectionImplApi35 {

        public Api35(cz.acrobits.libsoftphone.event.CallEvent event, boolean selfManaged) {
            super(event, selfManaged);
        }
    }
}
