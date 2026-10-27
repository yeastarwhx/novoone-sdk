package cz.acrobits.libsoftphone.data;

/**
 * SIP 头（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：Instance.Calls.findSipHeader(call, name)?.getValue()。
 */
public class SipHeader {

    private String mName;
    private String mValue;

    /** fastjson 序列化需要无参构造 */
    public SipHeader() {
        mName = null;
        mValue = null;
    }

    public SipHeader(String name, String value) {
        mName = name;
        mValue = value;
    }

    public String getName() {
        return mName;
    }

    public String getValue() {
        return mValue;
    }

    @Override
    public String toString() {
        return mName + ": " + mValue;
    }
}
