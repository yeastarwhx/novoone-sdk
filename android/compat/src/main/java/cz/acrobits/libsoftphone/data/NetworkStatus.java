package cz.acrobits.libsoftphone.data;

/**
 * 网络状态（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：getNetworkStatus(call)?.networkInterfaceName（通话质量网络显示）。
 */
public class NetworkStatus {

    /** fastjson 序列化需要无参构造 */
    public NetworkStatus() {
    }

    /** 当前网络接口名（"wifi" / "cellular" / "vpn" / "none"） */
    public String networkInterfaceName = "";
}
