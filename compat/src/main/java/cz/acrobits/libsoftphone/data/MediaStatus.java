package cz.acrobits.libsoftphone.data;

/**
 * 媒体状态（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：getMediaStatus(call)?.audio?.outgoingPayloadFriendlyName
 * （通话质量 codec 显示）。
 */
public class MediaStatus {

    /** fastjson 序列化需要无参构造 */
    public MediaStatus() {
    }

    public final AudioInfo audio = new AudioInfo();

    public static class AudioInfo {
        /** 出向音频 payload 友好名（如 "OPUS"；未知为空串） */
        public String outgoingPayloadFriendlyName = "";
    }
}
