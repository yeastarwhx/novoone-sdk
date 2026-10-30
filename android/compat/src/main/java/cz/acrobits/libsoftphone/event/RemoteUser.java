package cz.acrobits.libsoftphone.event;

/**
 * 事件远端用户（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：displayName（来显/被叫名）、genericUri（"nx:66669" 形态，
 * App 端取最后一个冒号后段为号码）、toStreamParty()。
 */
public class RemoteUser {

    public String displayName;
    public String genericUri;

    public RemoteUser() {
    }

    public RemoteUser(String displayName, String genericUri) {
        this.displayName = displayName;
        this.genericUri = genericUri;
    }

    /** 回转 StreamParty（取名诊断日志用） */
    public StreamParty toStreamParty() {
        StreamParty party = new StreamParty();
        party.displayName = displayName;
        party.setCurrentTransportUri(genericUri);
        return party;
    }

    @Override
    public String toString() {
        return "RemoteUser{displayName=" + displayName + ", uri=" + genericUri + '}';
    }
}
