package com.novosdk.account;

import com.novosdk.ali.Xml;
import com.novosdk.mergeable.MergeableNodeAttributes;

/**
 * 账户配置树（NovoSDK softphone API 层）。
 *
 * App 使用面（AccountDelegate 的 create/modify 流程）：
 * - 构造：new AccountXml(xml, MergeableNodeAttributes.gui())
 * - 修改：account.clone() → clone.mergeValue(key, value, attrs) /
 *   clone.setEnabled(false) → Instance.Registration.saveAccount(clone)
 * - 读取：account.xml.getAttribute(Account.Attributes.ID)、account.getString(key)
 */
public class AccountXml {

    /** 底层配置树（public 字段，App 直接访问 .xml.getAttribute） */
    public final Xml xml;

    private boolean mEnabled = true;

    /**
     * @param attributes 仅形态参数（对齐 Acrobits 构造签名），值合并
     *                   语义由 {@link #mergeValue} 覆写承担，本构造不使用
     */
    public AccountXml(Xml xml, MergeableNodeAttributes attributes) {
        this.xml = xml != null ? xml : new Xml("account");
    }

    /** 深拷贝（clone-and-modify 流程） */
    @Override
    public AccountXml clone() {
        AccountXml copy = new AccountXml(xml.copy(), MergeableNodeAttributes.gui());
        copy.mEnabled = mEnabled;
        return copy;
    }

    /** 合并子节点值（同名覆盖；attrs 仅形态参数） */
    public AccountXml mergeValue(String name, String value, MergeableNodeAttributes attributes) {
        if (name != null) {
            xml.setChildValue(name, value);
        }
        return this;
    }

    /** 账号启停（false = 注销） */
    public void setEnabled(boolean enabled) {
        mEnabled = enabled;
    }

    public boolean isEnabled() {
        return mEnabled;
    }

    /** 读取子节点值（childValue 优先；缺失返回 null） */
    public String getString(String name) {
        String v = xml.getChildValue(name);
        return v != null ? v : xml.getValue(name);
    }

    @Override
    public String toString() {
        return "AccountXml{enabled=" + mEnabled + ", xml=" + xml + "}";
    }
}
