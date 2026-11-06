package com.novosdk;

import com.novosdk.ali.Xml;

/**
 * NovoSDK Xml 树 ↔ 真身 ali.Xml 的桥。
 *
 * 通道 = XML 文本序列化往返（NovoSDK Xml.toString → 真身 Xml.parse；
 * 真身树 toString → NovoSDK Xml 解析）——两侧解析器各自可靠，避免手写
 * 树级深拷贝。委托化阶段核对序列化保真（provisioning/账户树节点完整性）。
 */
final class AcrobitsXml {

    private AcrobitsXml() {
    }

    /** NovoSDK 树 → 真身树（null 安全；失败时空 account 树兜底并记日志） */
    static cz.acrobits.ali.Xml fromNovosdk(Xml tree) {
        if (tree == null) {
            android.util.Log.w("Novosdk.AcrobitsXml", "toReal: tree is null");
            return new cz.acrobits.ali.Xml("account");
        }
        try {
            String serialized = tree.toString();
            android.util.Log.i("Novosdk.AcrobitsXml",
                    "toReal serialized len=" + serialized.length());
            cz.acrobits.ali.Xml parsed = cz.acrobits.ali.Xml.parse(serialized);
            if (parsed == null) {
                android.util.Log.w("Novosdk.AcrobitsXml", "real parse returned null");
                return new cz.acrobits.ali.Xml("account");
            }
            return parsed;
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.AcrobitsXml", "toReal failed: " + t
                    + ", fallback empty account tree");
            return new cz.acrobits.ali.Xml("account");
        }
    }

    /** 真身树 → NovoSDK 树（NovoSDK 侧解析入口为 parse(InputStream)） */
    static Xml fromReal(cz.acrobits.ali.Xml real) {
        if (real == null) {
            return null;
        }
        try {
            return Xml.parse(new java.io.ByteArrayInputStream(
                    real.toString().getBytes("UTF-8")));
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.AcrobitsXml", "fromReal failed: " + t);
            return null;
        }
    }
}
