package cz.acrobits.ali;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * JSON 值模型（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * 形态对齐 Acrobits：{@link Dict} 为键值容器（App 的 transients 存储通道），
 * 简单值经 {@link Dict#put(String, String)} 包裹存储；读取侧返回
 * java.util.Optional。内部仅用 LinkedHashMap。
 *
 * 注意：不能 extends JSONObject（getString 返回类型冲突：
 * Optional&lt;String&gt; vs String）。fastjson 序列化兼容靠
 * CallEvent.transients 上的 @JSONField(serialize=false, deserialize=false)
 * 跳过整个字段——桥层不传输 transients，Native 层内部使用不受影响。
 */
public class Json {

    /** 简单字符串值节点 */
    public static class StringValue extends Json {
        public final String value;

        public StringValue(String value) {
            this.value = value;
        }
    }

    /** 键值容器（transients 存储通道） */
    public static class Dict extends Json implements Map<String, Json> {

        /** fastjson 序列化需要无参构造 */
        public Dict() {
        }

        private final LinkedHashMap<String, Json> mMap = new LinkedHashMap<String, Json>();

        /** 字符串值写入 */
        public void put(String key, String value) {
            mMap.put(key, new StringValue(value != null ? value : ""));
        }

        @Override
        public Json put(String key, Json value) {
            return mMap.put(key, value != null ? value : new StringValue(""));
        }

        public Optional<String> getString(String key) {
            Json v = mMap.get(key);
            return v instanceof StringValue
                    ? Optional.of(((StringValue) v).value)
                    : Optional.empty();
        }

        public Optional<Dict> getDict(String key) {
            Json v = mMap.get(key);
            return v instanceof Dict ? Optional.of((Dict) v) : Optional.empty();
        }

        @Override
        public int size() { return mMap.size(); }

        @Override
        public boolean isEmpty() { return mMap.isEmpty(); }

        @Override
        public boolean containsKey(Object key) { return mMap.containsKey(key); }

        @Override
        public boolean containsValue(Object value) { return mMap.containsValue(value); }

        @Override
        public Json get(Object key) { return mMap.get(key); }

        @Override
        public Json remove(Object key) { return mMap.remove(key); }

        @Override
        public void putAll(Map<? extends String, ? extends Json> m) { mMap.putAll(m); }

        @Override
        public void clear() { mMap.clear(); }

        @Override
        public Set<String> keySet() { return mMap.keySet(); }

        @Override
        public java.util.Collection<Json> values() { return mMap.values(); }

        @Override
        public Set<Map.Entry<String, Json>> entrySet() { return mMap.entrySet(); }
    }

    /** 新建 Dict */
    public Dict newDict() {
        return new Dict();
    }
}
