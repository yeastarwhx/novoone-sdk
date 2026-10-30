package cz.acrobits.libsoftphone.data;

/**
 * 拨号动作（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：CallUtil.performCallAction 的 dialAction.id 存入
 * CallEvent.transients[CallEvent.Transients.DIAL_ACTION]。
 */
public enum DialAction {

    AudioCall("audioCall"),
    VideoCall("videoCall"),
    ServiceCall("serviceCall");

    /** 动作标识（transients 透传值） */
    public final String id;

    DialAction(String id) {
        this.id = id;
    }
}
