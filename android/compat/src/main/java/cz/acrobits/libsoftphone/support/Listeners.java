package cz.acrobits.libsoftphone.support;

import android.media.Ringtone;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import cz.acrobits.libsoftphone.NetworkType;
import cz.acrobits.libsoftphone.data.AudioRoute;
import cz.acrobits.libsoftphone.data.Call;
import cz.acrobits.libsoftphone.data.PushTestScheduleResult;
import cz.acrobits.libsoftphone.data.RegistrationState;
import cz.acrobits.libsoftphone.event.CallEvent;
import cz.acrobits.libsoftphone.event.Event;

/**
 * SDK 观察者聚合（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：
 * - SAM 接口：Listeners.OnXxx { ... } lambda / 类实现（NovoEventHandler）
 * - register(Object) / unregister(Object)：挂载/摘除监听对象
 * - 子类覆盖 getRingtone(call)：自定义来电铃声
 *
 * 分发：Instance.setObserver(observed) 后，引擎回调（SdkBridge）经
 * dispatchXxx 遍历已注册监听分发；单个监听异常不阻断其余分发。
 */
public class Listeners {

    /* ---------------- SAM 接口（App 实现面） ---------------- */

    public interface OnNewEvent {
        void onNewEvent(Event event);
    }

    /** 新呼叫（来电创建；NovoEventHandler 覆盖实现） */
    public interface OnNewCall {
        void onNewCall(CallEvent call);
    }

    public interface OnCallStateChanged {
        void onCallStateChanged(CallEvent event, Call.State state);
    }

    public interface OnCallHoldStateChanged {
        void onStateChanged(CallEvent event, Call.HoldStates states);
    }

    public interface OnNetworkChangeDetected {
        void onNetworkChangeDetected(NetworkType networkType);
    }

    public interface OnSettingsChanged {
        void onSettingsChanged();
    }

    public interface OnAudioRouteChanged {
        void onAudioRouteChanged(AudioRoute route);
    }

    public interface OnAudioAvailableRoutesChanged {
        void onAudioAvailableRoutesChanged(AudioRoute[] routes);
    }

    /** 媒体状态变化（App 注释明确：仅 CallEvent 参数，无 media 参数） */
    public interface OnMediaStatusChanged {
        void onMediaStatusChanged(CallEvent event);
    }

    public interface OnRegistrationStateChanged {
        void onRegistrationStateChanged(String accountId, RegistrationState state);
    }

    public interface OnPushTestArrived {
        void onPushTestArrived(String accountId);
    }

    public interface OnPushTestScheduled {
        void onPushTestScheduled(String accountId, PushTestScheduleResult result);
    }

    /* ---------------- 注册表 ---------------- */

    private final CopyOnWriteArrayList<Object> mRegistered = new CopyOnWriteArrayList<Object>();

    /** 挂载监听（任意 SAM 接口实现对象；重复注册幂等） */
    public void register(Object listener) {
        if (listener != null) {
            synchronized (mRegistered) {
                if (!mRegistered.contains(listener)) {
                    mRegistered.add(listener);
                }
            }
        }
    }

    /** 摘除监听 */
    public void unregister(Object listener) {
        if (listener != null) {
            synchronized (mRegistered) {
                mRegistered.remove(listener);
            }
        }
    }

    /** 已注册监听快照（内部/诊断用） */
    public List<Object> registered() {
        synchronized (mRegistered) {
            return new CopyOnWriteArrayList<Object>(mRegistered);
        }
    }

    /** 自定义来电铃声（子类覆盖；SDK 引擎侧来电时调用取铃声，null = 引擎默认铃声） */
    public Ringtone getRingtone(CallEvent call) {
        return null;
    }

    /* ---------------- 分发（SdkBridge 引擎回调侧调用） ---------------- */

    private interface Dispatch<T> {
        void dispatch(T listener) throws Exception;
    }

    private <T> void dispatch(Class<T> iface, Dispatch<T> body) {
        for (Object listener : mRegistered) {
            if (iface.isInstance(listener)) {
                try {
                    body.dispatch(iface.cast(listener));
                } catch (Throwable t) {
                    android.util.Log.w("Acrobits.Listeners",
                            "listener " + listener + " failed: " + t);
                }
            }
        }
    }

    public void dispatchNewEvent(final Event event) {
        dispatch(OnNewEvent.class, new Dispatch<OnNewEvent>() {
            @Override
            public void dispatch(OnNewEvent l) {
                l.onNewEvent(event);
            }
        });
    }

    public void dispatchNewCall(final CallEvent call) {
        dispatch(OnNewCall.class, new Dispatch<OnNewCall>() {
            @Override
            public void dispatch(OnNewCall l) {
                l.onNewCall(call);
            }
        });
    }

    public void dispatchCallStateChanged(final CallEvent event, final Call.State state) {
        dispatch(OnCallStateChanged.class, new Dispatch<OnCallStateChanged>() {
            @Override
            public void dispatch(OnCallStateChanged l) {
                l.onCallStateChanged(event, state);
            }
        });
    }

    public void dispatchCallHoldStateChanged(final CallEvent event, final Call.HoldStates states) {
        dispatch(OnCallHoldStateChanged.class, new Dispatch<OnCallHoldStateChanged>() {
            @Override
            public void dispatch(OnCallHoldStateChanged l) {
                l.onStateChanged(event, states);
            }
        });
    }

    public void dispatchNetworkChangeDetected(final NetworkType networkType) {
        dispatch(OnNetworkChangeDetected.class, new Dispatch<OnNetworkChangeDetected>() {
            @Override
            public void dispatch(OnNetworkChangeDetected l) {
                l.onNetworkChangeDetected(networkType);
            }
        });
    }

    public void dispatchSettingsChanged() {
        dispatch(OnSettingsChanged.class, new Dispatch<OnSettingsChanged>() {
            @Override
            public void dispatch(OnSettingsChanged l) {
                l.onSettingsChanged();
            }
        });
    }

    public void dispatchAudioRouteChanged(final AudioRoute route) {
        dispatch(OnAudioRouteChanged.class, new Dispatch<OnAudioRouteChanged>() {
            @Override
            public void dispatch(OnAudioRouteChanged l) {
                l.onAudioRouteChanged(route);
            }
        });
    }

    public void dispatchAudioAvailableRoutesChanged(final AudioRoute[] routes) {
        dispatch(OnAudioAvailableRoutesChanged.class, new Dispatch<OnAudioAvailableRoutesChanged>() {
            @Override
            public void dispatch(OnAudioAvailableRoutesChanged l) {
                l.onAudioAvailableRoutesChanged(routes);
            }
        });
    }

    public void dispatchMediaStatusChanged(final CallEvent event) {
        dispatch(OnMediaStatusChanged.class, new Dispatch<OnMediaStatusChanged>() {
            @Override
            public void dispatch(OnMediaStatusChanged l) {
                l.onMediaStatusChanged(event);
            }
        });
    }

    public void dispatchRegistrationStateChanged(final String accountId,
                                                 final RegistrationState state) {
        dispatch(OnRegistrationStateChanged.class, new Dispatch<OnRegistrationStateChanged>() {
            @Override
            public void dispatch(OnRegistrationStateChanged l) {
                l.onRegistrationStateChanged(accountId, state);
            }
        });
    }
}
