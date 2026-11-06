package com.novosdk;

import com.novosdk.account.AccountXml;
import com.novosdk.mergeable.MergeableNodeAttributes;

/**
 * NovoSDK AccountXml ↔ 真身 AccountXml 的桥（XML 文本往返，同
 * {@link AcrobitsXml} 通道）。账户树节点在两侧解析器间保真往返，
 * 委托化阶段逐节点核对（username/host/transport/proxy/expires 等）。
 */
final class AccountBridge {

    private AccountBridge() {
    }

    static cz.acrobits.libsoftphone.account.AccountXml toReal(AccountXml account) {
        if (account == null) {
            return null;
        }
        cz.acrobits.ali.Xml realTree = AcrobitsXml.fromNovosdk(account.xml);
        // 双参构造：MergeableNodeAttributes.gui()——GUI 来源（用户配置），
        // 字段带 source/priority 元数据，真身 saveAccount 才会抽取字段
        // （单参构造的字段因无元数据被忽略——只建骨架，S3 诊断实证）
        cz.acrobits.libsoftphone.account.AccountXml out = realTree != null
                ? new cz.acrobits.libsoftphone.account.AccountXml(realTree,
                        cz.acrobits.libsoftphone.mergeable.MergeableNodeAttributes.gui())
                : null;
        try {
            android.util.Log.i("Novosdk.AccountBridge", "toReal result: out="
                    + (out != null)
                    + " username=" + (out != null ? out.getString("username") : "-")
                    + " host=" + (out != null ? out.getString("host") : "-")
                    + " realTree=" + (realTree != null ? realTree.toString() : "null").substring(0, 200));
        } catch (Throwable ignored) {
        }
        return out;
    }

    static AccountXml fromReal(cz.acrobits.libsoftphone.account.AccountXml real) {
        if (real == null) {
            return null;
        }
        try {
            com.novosdk.ali.Xml tree = com.novosdk.ali.Xml.parse(
                    new java.io.ByteArrayInputStream(
                            real.toString().getBytes("UTF-8")));
            return new AccountXml(tree, MergeableNodeAttributes.gui());
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.AccountBridge", "fromReal failed: " + t);
            return null;
        }
    }
}
