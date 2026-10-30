package cz.acrobits.libsoftphone.event;

/**
 * 通话参与方（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：new StreamParty(number).match(null).toRemoteUser()（拨号）、
 * displayName / getCurrentOriginalTransportUri()（取名诊断）。
 */
public class StreamParty {

    /** 显示名（来显；未设置为 null） */
    public String displayName;

    private String mCurrentTransportUri;

    public StreamParty() {
    }

    public StreamParty(String number) {
        mCurrentTransportUri = number;
    }

    /** 账号匹配（账号树解析；本引擎单账号，恒返回 this 保持链式调用） */
    public StreamParty match(String accountId) {
        return this;
    }

    public void setCurrentTransportUri(String uri) {
        mCurrentTransportUri = uri;
    }

    /** 当前传输 URI（未设置为 null） */
    public String getCurrentTransportUri() {
        return mCurrentTransportUri;
    }

    /** 原始传输 URI（未经过账号改写，与当前一致） */
    public String getCurrentOriginalTransportUri() {
        return mCurrentTransportUri;
    }

    /** 转远端用户（拨号组事件用） */
    public RemoteUser toRemoteUser() {
        return new RemoteUser(displayName, mCurrentTransportUri);
    }

    @Override
    public String toString() {
        return "StreamParty{displayName=" + displayName + ", uri=" + mCurrentTransportUri + '}';
    }
}
