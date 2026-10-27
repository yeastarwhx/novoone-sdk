package cz.acrobits.libsoftphone.data;

/**
 * 通话类型与状态（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * 枚举名即 App 契约（Kotlin when / Java switch 按 name 匹配），不可改动。
 */
public final class Call {

    private Call() {
    }

    /** 通话状态（App 大量按 name 比较；isTerminal 标记终态） */
    public enum State {
        Trying, Ringing, Established, Error,
        IncomingTrying, IncomingRinging, IncomingIgnored,
        IncomingAnswered, IncomingRejected, IncomingMissed,
        IncomingForwarded, IncomingAnsweredElsewhere;

        /** 是否终态（通话已结束，不再迁移） */
        public boolean isTerminal() {
            return this == Error
                    || this == IncomingIgnored
                    || this == IncomingRejected
                    || this == IncomingMissed
                    || this == IncomingForwarded
                    || this == IncomingAnsweredElsewhere;
        }
    }

    /** 保持状态（未保持时 HoldStates.local/remote 为 null） */
    public enum HoldState {
        Held
    }

    /** 本端/对端保持状态对 */
    public static final class HoldStates {
        public final HoldState local;
        public final HoldState remote;

        public HoldStates(HoldState local, HoldState remote) {
            this.local = local;
            this.remote = remote;
        }

        @Override
        public String toString() {
            return "HoldStates{local=" + local + ", remote=" + remote + '}';
        }
    }

    /** 拒接原因类型（RejectReason.Type 的独立常量形态，兼容两种引用路径） */
    public enum RejectReasonType {
        User
    }

    /** 拒接原因（App 构造 new Call.RejectReason("...", Call.RejectReason.Type.User)） */
    public static final class RejectReason {

        /** 拒接原因类型 */
        public enum Type {
            User
        }

        public final String description;
        public final Type type;

        public RejectReason(String description, Type type) {
            this.description = description;
            this.type = type;
        }

        public RejectReason(String description, RejectReasonType type) {
            this.description = description;
            this.type = type == RejectReasonType.User ? Type.User : null;
        }

        @Override
        public String toString() {
            return "RejectReason{" + description + ", type=" + type + '}';
        }
    }

    /** 期望媒体（voiceOnly = 本期唯一形态：纯语音） */
    public static final class DesiredMedia {
        private DesiredMedia() {
        }

        public static DesiredMedia voiceOnly() {
            return new DesiredMedia();
        }

        public static DesiredMedia videoBothWays() {
            return new DesiredMedia();
        }
    }

    /** 通话属性名（App 使用 Call.Attributes.ID） */
    public static final class Attributes {
        public static final String ID = "id";

        private Attributes() {
        }
    }
}
