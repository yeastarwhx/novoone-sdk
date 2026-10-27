package cz.acrobits.libsoftphone.data;

/**
 * 通话统计（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * 字段语义按 App 消费方式对齐：
 * - maxJitter 为时钟 tick 单位，App 按 clockRateInHertz 换算毫秒；
 * - jitterBufferPacketLossPercentage 为百分比整数（0-100）；
 * - meteredNetworkJitter 为微秒。
 * 数据源：SipWebrtcEngine.WebRTC getStats 缓存（SdkBridge 1s 轮询）。
 */
public class CallStatistics {

    /** fastjson 序列化需要无参构造 */
    public CallStatistics() {
    }

    /** 编解码时钟率（Opus 48000） */
    public int clockRateInHertz = 48000;

    /** 最大抖动（tick 单位：jitterMs * clockRate / 1000） */
    public int maxJitter;

    /** 抖动缓冲丢包率（百分比，0-100） */
    public int jitterBufferPacketLossPercentage;

    /** 网络抖动（微秒） */
    public long meteredNetworkJitter;

    /** 平均往返时延（毫秒） */
    public int avgRoundTripTimeInMilliseconds;

    @Override
    public String toString() {
        return "CallStatistics{clockRate=" + clockRateInHertz
                + "Hz, maxJitter=" + maxJitter
                + ", loss=" + jitterBufferPacketLossPercentage + "%"
                + ", netJitter=" + meteredNetworkJitter + "us"
                + ", rtt=" + avgRoundTripTimeInMilliseconds + "ms}";
    }
}
