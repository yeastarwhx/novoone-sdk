package com.novosdk;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/**
 * 真身 Observer → NovoSDK Listeners 的回调转译桥（adapter 内部）。
 *
 * 实现 = JDK 动态代理：真身 Observer 的 43 个方法中，App 消费的 12 个按
 * 方法名转分发到 {@link com.novosdk.support.Listeners} 的 dispatchXxx，
 * 其余返回默认值（null/false/0）。动态代理避免了 adapter 对未消费回调
 * 的参数类型（Balance$Record 等，分布在多个 artifact）的编译期依赖。
 *
 * getRingtone 为反向钩子（真身来电取铃声 → App 子类覆盖）。
 * onNewCall：NovoSDK 自创语义（compat 从引擎事件派生）——由 onNewEvent
 * 推导（event 为 CallEvent 时追加派发），真机回归核对派发条件。
 */
final class ObserverBridge implements InvocationHandler {

    private final com.novosdk.support.Listeners target;

    private ObserverBridge(com.novosdk.support.Listeners target) {
        this.target = target;
    }

    /** 创建注册给真身的 Observer 代理 */
    static cz.acrobits.libsoftphone.Observer create(com.novosdk.support.Listeners target) {
        return (cz.acrobits.libsoftphone.Observer) Proxy.newProxyInstance(
                cz.acrobits.libsoftphone.Observer.class.getClassLoader(),
                new Class<?>[]{cz.acrobits.libsoftphone.Observer.class},
                new ObserverBridge(target));
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        try {
            return dispatch(method.getName(), args);
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.ObserverBridge",
                    method.getName() + " dispatch failed: " + t);
            return defaultValue(method.getReturnType());
        }
    }

    private Object dispatch(String name, Object[] args) {
        if ("getRingtone".equals(name)) {
            return target.getRingtone(Bridge.wrap(
                    (cz.acrobits.libsoftphone.event.CallEvent) args[0]));
        }
        if ("onNewEvent".equals(name) && args != null && args.length == 1
                && args[0] instanceof cz.acrobits.libsoftphone.event.CallEvent) {
            com.novosdk.event.CallEvent wrapped = Bridge.wrap(
                    (cz.acrobits.libsoftphone.event.CallEvent) args[0]);
            target.dispatchNewEvent(wrapped);
            target.dispatchNewCall(wrapped);
            return null;
        }
        if ("onCallStateChanged".equals(name)) {
            target.dispatchCallStateChanged(Bridge.wrap(event(args)),
                    Bridge.convCallState(
                            (cz.acrobits.libsoftphone.data.Call.State) args[1]));
            return null;
        }
        if ("onCallHoldStateChanged".equals(name)) {
            target.dispatchCallHoldStateChanged(Bridge.wrap(event(args)),
                    Bridge.wrapHoldStates(holdStates(args)));
            return null;
        }
        if ("onMediaStatusChanged".equals(name)) {
            target.dispatchMediaStatusChanged(Bridge.wrap(event(args)));
            return null;
        }
        if ("onAudioRouteChanged".equals(name)) {
            target.dispatchAudioRouteChanged(Bridge.convertEnum(
                    (Enum<?>) args[0], com.novosdk.data.AudioRoute.class));
            return null;
        }
        if ("onAudioAvailableRoutesChanged".equals(name)) {
            Enum<?>[] real = (Enum<?>[]) args[0];
            com.novosdk.data.AudioRoute[] out = new com.novosdk.data.AudioRoute[real.length];
            for (int i = 0; i < real.length; i++) {
                out[i] = Bridge.convertEnum(real[i], com.novosdk.data.AudioRoute.class);
            }
            target.dispatchAudioAvailableRoutesChanged(out);
            return null;
        }
        if ("onNetworkChangeDetected".equals(name)) {
            target.dispatchNetworkChangeDetected(Bridge.convertNetwork(
                    (cz.acrobits.libsoftphone.network.Network) args[0]));
            return null;
        }
        if ("onRegistrationStateChanged".equals(name)) {
            target.dispatchRegistrationStateChanged((String) args[0],
                    Bridge.convRegState(
                            (cz.acrobits.libsoftphone.data.RegistrationState) args[1]));
            return null;
        }
        if ("onSettingsChanged".equals(name)) {
            target.dispatchSettingsChanged();
            return null;
        }
        if ("onPushTestArrived".equals(name)) {
            target.dispatchPushTestArrived((String) args[0]);
            return null;
        }
        if ("onPushTestScheduled".equals(name)) {
            // PushTestScheduleResult：真身失败值集经专用映射归 Failure（审查修复）
            target.dispatchPushTestScheduled((String) args[0],
                    Bridge.convPushTestResult(
                            (cz.acrobits.libsoftphone.data.PushTestScheduleResult) args[1]));
            return null;
        }
        if ("onCallThroughResult".equals(name)) {
            return Boolean.FALSE;
        }
        // 其余未消费回调：默认值
        return null;
    }

    private static cz.acrobits.libsoftphone.event.CallEvent event(Object[] args) {
        return (cz.acrobits.libsoftphone.event.CallEvent) args[0];
    }

    private static cz.acrobits.libsoftphone.data.Call.HoldStates holdStates(Object[] args) {
        return (cz.acrobits.libsoftphone.data.Call.HoldStates) args[1];
    }

    private static Object defaultValue(Class<?> returnType) {
        if (returnType == Boolean.TYPE) {
            return Boolean.FALSE;
        }
        if (returnType == Integer.TYPE) {
            return 0;
        }
        return null;
    }
}
