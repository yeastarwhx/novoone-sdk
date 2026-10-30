package cz.acrobits.libsoftphone.data;

/**
 * 对端地址解析（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：new ResolvedPeerAddress(uri).getHumanReadable()——displayName
 * 为空时从 URI 提取可读号码。
 */
public class ResolvedPeerAddress {

    private final String mAddress;

    public ResolvedPeerAddress(String address) {
        mAddress = address != null ? address : "";
    }

    /**
     * 可读形式：剥离 URI 前缀（"nx:66669" → "66669"；"sip:1000@host" →
     * "1000"；无分隔符原样返回）。
     */
    public String getHumanReadable() {
        String a = mAddress.trim();
        int colon = a.lastIndexOf(':');
        if (colon >= 0 && colon + 1 < a.length()) {
            a = a.substring(colon + 1);
        }
        int at = a.indexOf('@');
        if (at > 0) {
            a = a.substring(0, at);
        }
        return a;
    }

    @Override
    public String toString() {
        return mAddress;
    }
}
