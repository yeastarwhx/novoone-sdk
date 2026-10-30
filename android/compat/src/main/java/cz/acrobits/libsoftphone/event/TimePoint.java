package cz.acrobits.libsoftphone.event;

/**
 * 时间点（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：callEvent.timeEstablished?.toMilliseconds()。
 * 未建立时 timeEstablished 字段为 null（平台类型可空语义）。
 */
public class TimePoint {

    private long mMilliseconds;

    /** fastjson 序列化需要无参构造（App 经 fastjson 序列化整个 CallEvent） */
    public TimePoint() {
        mMilliseconds = 0;
    }

    public TimePoint(long milliseconds) {
        mMilliseconds = milliseconds;
    }

    public long toMilliseconds() {
        return mMilliseconds;
    }

    @Override
    public String toString() {
        return String.valueOf(mMilliseconds);
    }
}
