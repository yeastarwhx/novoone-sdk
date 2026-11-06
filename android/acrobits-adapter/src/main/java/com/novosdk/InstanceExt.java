package com.novosdk;

import com.novosdk.event.CallEvent;

import java.util.Arrays;
import java.util.stream.Stream;

/**
 * Instance 扩展门面（NovoSDK API 层，Acrobits 后端）。
 *
 * App 使用面（CallUtil）：InstanceExt.Calls.Conferences.getAllCalls(confId)
 * → Stream&lt;CallEvent&gt;。26 形态经真身 Conferences.getCalls 取组内通话
 * （真身真组呼模型，语义与 126 单腿组模型差异在回归阶段核对）。
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
                return Arrays.stream(Bridge.wrapAllArray(
                        cz.acrobits.libsoftphone.Instance.Calls.Conferences
                                .getCalls(conferenceId)));
            }
        }
    }
}
