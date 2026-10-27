package cz.acrobits.ali;

import org.xmlpull.v1.XmlPullParser;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 轻量 XML 节点（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：provisioning 解析（{@link #parse(InputStream)}）、push payload
 * 组包（{@link #toXml(String, Map)}）、账户配置树（setAttribute /
 * setChildValue / setChild / getAttribute / getChildValue）。
 * 实现：属性表 + 子值表（叶文本）+ 子节点表；解析走系统 XmlPullParser。
 */
public class Xml {

    private final String mName;
    private final LinkedHashMap<String, String> mAttributes = new LinkedHashMap<String, String>();
    /** 叶子文本值：childName -> text（setChildValue 写入） */
    private final LinkedHashMap<String, String> mChildValues = new LinkedHashMap<String, String>();
    /** 重复子节点（setChild 追加；按名取首个） */
    private final List<Xml> mChildren = new ArrayList<Xml>();

    public Xml(String name) {
        mName = name != null ? name : "node";
    }

    /** 名称为 "xml" 的空节点 */
    public static Xml create() {
        return new Xml("xml");
    }

    /* ---------------- 构建 ---------------- */

    public Xml setAttribute(String name, String value) {
        if (name != null) {
            mAttributes.put(name, value);
        }
        return this;
    }

    public Xml setChildValue(String name, String value) {
        if (name != null) {
            mChildValues.put(name, value != null ? value : "");
        }
        return this;
    }

    public Xml setChild(Xml child) {
        if (child != null) {
            mChildren.add(child);
        }
        return this;
    }

    /** Map → 子值集（push payload 组包用） */
    public static Xml toXml(String name, Map<String, String> map) {
        Xml xml = new Xml(name);
        if (map != null) {
            for (Map.Entry<String, String> e : map.entrySet()) {
                xml.setChildValue(e.getKey(), e.getValue());
            }
        }
        return xml;
    }

    /* ---------------- 读取 ---------------- */

    public String getName() {
        return mName;
    }

    public String getAttribute(String name) {
        return name != null ? mAttributes.get(name) : null;
    }

    /** 叶子文本值（setChildValue / 解析的叶文本） */
    public String getChildValue(String name) {
        return name != null ? mChildValues.get(name) : null;
    }

    /** 同名子节点值（子值表缺失时查子节点表） */
    public String getValue(String name) {
        String v = getChildValue(name);
        if (v != null) {
            return v;
        }
        for (Xml child : mChildren) {
            if (child.mName.equals(name)) {
                return child.getChildValue(name);
            }
        }
        return null;
    }

    public List<Xml> getChildren() {
        return mChildren;
    }

    /** 深拷贝（账户 clone-and-modify 流程用） */
    public Xml copy() {
        Xml copy = new Xml(mName);
        copy.mAttributes.putAll(mAttributes);
        copy.mChildValues.putAll(mChildValues);
        for (Xml child : mChildren) {
            copy.mChildren.add(child.copy());
        }
        return copy;
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("<").append(mName);
        for (Map.Entry<String, String> e : mAttributes.entrySet()) {
            sb.append(' ').append(e.getKey()).append("=\"").append(e.getValue()).append('"');
        }
        sb.append('>');
        for (Map.Entry<String, String> e : mChildValues.entrySet()) {
            sb.append('<').append(e.getKey()).append('>')
                    .append(e.getValue())
                    .append("</").append(e.getKey()).append('>');
        }
        for (Xml child : mChildren) {
            sb.append(child.toString());
        }
        sb.append("</").append(mName).append('>');
        return sb.toString();
    }

    /* ---------------- 解析 ---------------- */

    /**
     * 输入流解析为节点树（provisioning.xml 等小文档）。
     * 失败（空流/异常）返回 null，调用方按"无 provisioning"处理。
     */
    public static Xml parse(InputStream is) {
        if (is == null) {
            return null;
        }
        try {
            XmlPullParser parser = android.util.Xml.newPullParser();
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false);
            parser.setInput(is, null);
            List<Xml> stack = new ArrayList<Xml>();
            Xml root = null;
            int event = parser.getEventType();
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG) {
                    Xml node = new Xml(parser.getName());
                    for (int i = 0; i < parser.getAttributeCount(); i++) {
                        node.setAttribute(parser.getAttributeName(i), parser.getAttributeValue(i));
                    }
                    if (stack.isEmpty()) {
                        root = node;
                    } else {
                        stack.get(stack.size() - 1).mChildren.add(node);
                    }
                    stack.add(node);
                } else if (event == XmlPullParser.TEXT) {
                    String text = parser.getText();
                    if (!stack.isEmpty() && text != null && text.trim().length() > 0) {
                        stack.get(stack.size() - 1)
                                .mChildValues.put("#text", text.trim());
                    }
                } else if (event == XmlPullParser.END_TAG) {
                    if (!stack.isEmpty()) {
                        Xml closed = stack.remove(stack.size() - 1);
                        /* 叶文本上提为 childValue（子名 = 自身节点名），与
                         * setChildValue 的读写形态对齐 */
                        String text = closed.mChildValues.remove("#text");
                        if (text != null && closed.mChildren.isEmpty()
                                && !closed.mChildValues.containsKey(closed.mName)) {
                            closed.mChildValues.put(closed.mName, text);
                        }
                    }
                }
                event = parser.next();
            }
            return root;
        } catch (Exception e) {
            android.util.Log.w("Acrobits.Xml", "parse failed: " + e);
            return null;
        }
    }
}
