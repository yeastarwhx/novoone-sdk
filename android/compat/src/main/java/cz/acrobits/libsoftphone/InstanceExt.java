package cz.acrobits.libsoftphone;

import com.yeastar.sipcore.SdkBridge;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Stream;

import cz.acrobits.libsoftphone.event.CallEvent;

/**
 * Instance 扩展门面（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面（CallUtil）：InstanceExt.Calls.Conferences.getAllCalls(confId)
 * → Stream&lt;CallEvent&gt;（会议组全量通话流式遍历）。
 *
 * 结构与 {@link Instance} 一致：嵌套类 + 静态方法（保证嵌套类型路径引用
 * 在两种语言下均可解析）。
 */
public final class InstanceExt {

    private InstanceExt() {
    }

    /** 扩展 Calls 模块 */
    public static final class Calls {

        /** 扩展 Conferences 模块 */
        public static final class Conferences {

            /** 组内全量通话（Stream 形态，filter/anyMatch/concat 消费） */
            public static Stream<CallEvent> getAllCalls(String conferenceId) {
                List<CallEvent> calls = new ArrayList<CallEvent>();
                for (com.yeastar.sipcore.CallSession s
                        : SdkBridge.get().sessionsOfGroup(conferenceId)) {
                    calls.add(SdkBridge.get().wrapEvent(s));
                }
                return calls.stream();
            }
        }
    }
}
