package com.novosdk;

import com.novosdk.data.Call;
import com.novosdk.data.CallStatistics;
import com.novosdk.data.MediaStatus;
import com.novosdk.data.NetworkStatus;
import com.novosdk.event.CallEvent;
import com.novosdk.event.RemoteUser;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * NovoSDK ↔ Acrobits 真身的跨边界转换器（adapter 内部）。
 *
 * 身份缓存：同一真身事件多次包装返回同一 NovoSDK 实例（App 端 transients
 * 等 attach 状态存续；语义对齐 :novosdk 侧"App 持续持有同一实例"契约）。
 * 枚举按 name() 直转（compat 枚举值名仿 Acrobits），字段拷贝骨架版——
 * 委托化阶段核对逐字段语义。
 */
public final class Bridge {

    private static final Map<cz.acrobits.libsoftphone.event.CallEvent, CallEvent> sWrap =
            java.util.Collections.synchronizedMap(
                    new java.util.WeakHashMap<cz.acrobits.libsoftphone.event.CallEvent, CallEvent>());
    private static final Map<CallEvent, cz.acrobits.libsoftphone.event.CallEvent> sUnwrap =
            java.util.Collections.synchronizedMap(
                    new java.util.WeakHashMap<CallEvent, cz.acrobits.libsoftphone.event.CallEvent>());

    private Bridge() {
    }

    /* ---------------- CallEvent 双向 ---------------- */

    /** 真身 → NovoSDK（身份缓存；事件结束后条目由 Instance 侧清理钩子移除，骨架期容忍增长） */
    public static CallEvent wrap(cz.acrobits.libsoftphone.event.CallEvent real) {
        if (real == null) {
            return null;
        }
        CallEvent wrapped = sWrap.get(real);
        if (wrapped == null) {
            wrapped = new CallEvent(wrapRemoteUser(real.getRemoteUser()));
            wrapped.setEventId(real.getEventId());
            try {
                wrapped.accountId = Integer.parseInt(real.getAccountId());
            } catch (NumberFormatException ignored) {
                // 真身 accountId 为字符串；NovoSDK 形状为 int（单账户场景
                // "0"→0，S3 真机验证呼出/呼入账号路由正常）
            }
            sWrap.put(real, wrapped);
            sUnwrap.put(wrapped, real);
        }
        // 动态字段每次刷新（身份缓存不回灌）：计时器数据源
        // timeEstablished 通话建立时才写入真身事件——真身 Timestamp 为
        // double 秒，NovoSDK TimePoint 为 long 毫秒
        if (real.getTimeEstablished() != null) {
            java.util.Date d = real.getTimeEstablished().toDate();
            wrapped.timeEstablished = new com.novosdk.event.TimePoint(
                    d != null ? d.getTime() : 0L);
        }
        return wrapped;
    }

    /** NovoSDK → 真身（unwrap 缺失（App 自构事件如拨号）时按包装侧字段新建） */
    public static cz.acrobits.libsoftphone.event.CallEvent unwrap(CallEvent event) {
        if (event == null) {
            return null;
        }
        cz.acrobits.libsoftphone.event.CallEvent real = sUnwrap.get(event);
        if (real == null) {
            real = new cz.acrobits.libsoftphone.event.CallEvent(
                    unwrapRemoteUser(event.remoteUser));
            // 真身 eventId 由 native 分配（无 setter）——App 自构事件（拨号）
            // 的 eventId 在 post 后由真身侧确立，wrap 侧经身份缓存回读
            sUnwrap.put(event, real);
            sWrap.put(real, event);
        }
        return real;
    }

    static List<CallEvent> wrapAll(cz.acrobits.libsoftphone.event.CallEvent[] arr) {
        List<CallEvent> out = new ArrayList<CallEvent>();
        if (arr != null) {
            for (cz.acrobits.libsoftphone.event.CallEvent e : arr) {
                out.add(wrap(e));
            }
        }
        return out;
    }

    static CallEvent[] wrapAllArray(cz.acrobits.libsoftphone.event.CallEvent[] arr) {
        if (arr == null) {
            return new CallEvent[0];
        }
        CallEvent[] out = new CallEvent[arr.length];
        for (int i = 0; i < arr.length; i++) {
            out[i] = wrap(arr[i]);
        }
        return out;
    }

    /* ---------------- RemoteUser ---------------- */

    static RemoteUser wrapRemoteUser(cz.acrobits.libsoftphone.event.RemoteUser real) {
        if (real == null) {
            return null;
        }
        RemoteUser u = new RemoteUser();
        u.displayName = real.getDisplayName();
        // NovoSDK 形状的 genericUri 字段承载的是"可拨 URI"（App 侧
        // toRemoteUser 即 transportUri 存入），来显侧真身 transportUri
        // 优先，genericUri 兜底
        u.genericUri = real.getTransportUri() != null
                ? real.getTransportUri() : real.getGenericUri();
        return u;
    }

    static cz.acrobits.libsoftphone.event.RemoteUser unwrapRemoteUser(RemoteUser user) {
        if (user == null) {
            return null;
        }
        cz.acrobits.libsoftphone.event.RemoteUser r =
                new cz.acrobits.libsoftphone.event.RemoteUser();
        r.setDisplayName(user.displayName != null ? user.displayName : "");
        if (user.genericUri != null) {
            // 拨号方向：NovoSDK genericUri 承载 transportUri（INVITE 的
            // Request-URI 来源）——两侧同值双设
            r.setTransportUri(user.genericUri);
            r.setGenericUri(user.genericUri);
        }
        return r;
    }

    /* ---------------- 枚举（name 直转，委托化阶段核对值集） ---------------- */

    /** 真身 Network(None/Cellular/Wifi) → NovoSDK NetworkType（MOBILE/WIFI/NONE） */
    static NetworkType convertNetwork(cz.acrobits.libsoftphone.network.Network real) {
        if (real == null) {
            return NetworkType.NONE;
        }
        switch (real) {
            case Wifi:
                return NetworkType.WIFI;
            case Cellular:
                return NetworkType.MOBILE;
            default:
                return NetworkType.NONE;
        }
    }

    /** RejectReason 深转换（NovoSDK Type{User} ⊂ 真身 Type；非 User 降级 User） */
    static Call.RejectReason wrapRejectReason(
            cz.acrobits.libsoftphone.data.Call.RejectReason real) {
        if (real == null) {
            return null;
        }
        return new Call.RejectReason(
                real.getDescription() != null ? real.getDescription() : "",
                Call.RejectReason.Type.User);
    }

    static cz.acrobits.libsoftphone.data.Call.RejectReason unwrapRejectReason(
            Call.RejectReason reason) {
        if (reason == null) {
            return null;
        }
        return new cz.acrobits.libsoftphone.data.Call.RejectReason(
                reason.description,
                cz.acrobits.libsoftphone.data.Call.RejectReason.Type.User);
    }

    static <E extends Enum<E>> E convertEnum(Enum<?> value, Class<E> target) {
        if (value == null) {
            return null;
        }
        try {
            return Enum.valueOf(target, value.name());
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /* ---------------- 状态枚举专用映射（真身值集 ⊃ NovoSDK 契约值集） ----------------
     *
     * convertEnum 按 name() 直转，真身枚举中 NovoSDK 契约没有的值会得到 null，
     * 下发后 App 侧 Kotlin 非空参数立即 NPE（2026-11-06 代码审查实证：挂断
     * Terminated/注册失败 Error 等路径的状态回调被吞）。以下映射对齐
     * :novosdk（126 契约）SdkBridge 的既定语义：Terminated 保持 Established
     * （终态判定以会话消失为准）、错误态归 Error、注册过渡态归 3 值契约。
     */

    /** 真身 Call.State → NovoSDK（全值覆盖，无 null 出口） */
    static Call.State convCallState(cz.acrobits.libsoftphone.data.Call.State real) {
        if (real == null) {
            return Call.State.Error;
        }
        switch (real) {
            case Terminated:
                return Call.State.Established; /* 对齐 126：终态判定以会话为准 */
            case Busy:
            case Unauthorized:
            case Unknown:
            case RedirectedToAlternativeService:
                return Call.State.Error;
            default:
                Call.State v = convertEnum(real, Call.State.class);
                return v != null ? v : Call.State.Error;
        }
    }

    /** 真身 RegistrationState → NovoSDK 3 值契约（过渡态归 Registering，失败终态归 NotRegistered） */
    static com.novosdk.data.RegistrationState convRegState(
            cz.acrobits.libsoftphone.data.RegistrationState real) {
        if (real == null) {
            return com.novosdk.data.RegistrationState.NotRegistered;
        }
        switch (real) {
            case None:
            case Discovering:
            case PushHandshake:
            case Unregistering:
                return com.novosdk.data.RegistrationState.Registering;
            case Unauthorized:
            case Error:
                return com.novosdk.data.RegistrationState.NotRegistered;
            default:
                com.novosdk.data.RegistrationState v =
                        convertEnum(real, com.novosdk.data.RegistrationState.class);
                return v != null ? v : com.novosdk.data.RegistrationState.NotRegistered;
            }
    }

    /** 真身 PushTestScheduleResult → NovoSDK（失败值集归 Failure） */
    static com.novosdk.data.PushTestScheduleResult convPushTestResult(
            cz.acrobits.libsoftphone.data.PushTestScheduleResult real) {
        if (real == null) {
            return com.novosdk.data.PushTestScheduleResult.Failure;
        }
        switch (real) {
            case Timeout:
            case PushNotEnabled:
            case NoPushToken:
                return com.novosdk.data.PushTestScheduleResult.Failure;
            default:
                com.novosdk.data.PushTestScheduleResult v = convertEnum(
                        real, com.novosdk.data.PushTestScheduleResult.class);
                return v != null ? v : com.novosdk.data.PushTestScheduleResult.Failure;
        }
    }

    /* ---------------- Hold/NetworkStatus/MediaStatus（结构体拷贝） ---------------- */

    /** 真身 HoldState(None/Active/Pending/Held) → NovoSDK(仅 Held，未保持为 null) */
    static Call.HoldState convHoldState(cz.acrobits.libsoftphone.data.Call.HoldState real) {
        return real == cz.acrobits.libsoftphone.data.Call.HoldState.Held
                ? Call.HoldState.Held : null;
    }

    static Call.HoldStates wrapHoldStates(cz.acrobits.libsoftphone.data.Call.HoldStates real) {
        if (real == null) {
            return null;
        }
        return new Call.HoldStates(convHoldState(real.local), convHoldState(real.remote));
    }

    static NetworkStatus wrapNetworkStatus(cz.acrobits.libsoftphone.data.NetworkStatus real) {
        NetworkStatus out = new NetworkStatus();
        if (real != null) {
            // NovoSDK 形状仅此字段（:novosdk 规格）；真身的 friendlyName/
            // detectedNat 等富字段按需在委托化阶段扩 NovoSDK 形状
            out.networkInterfaceName = real.networkInterfaceName;
        }
        return out;
    }

    static MediaStatus wrapMediaStatus(cz.acrobits.libsoftphone.data.Call.MediaStatus real) {
        MediaStatus out = new MediaStatus();
        if (real != null && real.audio != null) {
            out.audio.outgoingPayloadFriendlyName =
                    real.audio.outgoingPayloadFriendlyName != null
                            ? real.audio.outgoingPayloadFriendlyName : "";
        }
        return out;
    }

    /* ---------------- 统计（骨架空对象，委托化阶段补字段拷贝） ---------------- */

    static CallStatistics wrapStatistics(cz.acrobits.libsoftphone.data.Call.Statistics real) {
        CallStatistics out = new CallStatistics();
        if (real != null) {
            out.clockRateInHertz = real.clockRateInHertz;
            // NovoSDK maxJitter 为 tick 量纲（ms*clockRate/1000），真身为
            // double（ms 语义）——直拷取整，UI 展示量级一致
            out.maxJitter = (int) real.maxJitter;
            out.jitterBufferPacketLossPercentage = real.jitterBufferPacketLossPercentage;
            out.meteredNetworkJitter = real.meteredNetworkJitter;
            out.avgRoundTripTimeInMilliseconds = real.avgRoundTripTimeInMilliseconds;
        }
        return out;
    }
}
