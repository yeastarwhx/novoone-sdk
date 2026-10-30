package cz.acrobits.libsoftphone.data;

/**
 * 音频路由（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * ⚠️ ordinal 顺序为 App 侧二进制契约（ActiveCallItem.audioRoute 传 ordinal
 * 给 RN），必须保持：Unselected=0, Receiver=1, Speaker=2, BluetoothSCO=3,
 * BluetoothA2DP=4, Headset=5。
 */
public enum AudioRoute {
    Unselected,
    Receiver,
    Speaker,
    BluetoothSCO,
    BluetoothA2DP,
    Headset
}
