package cz.acrobits.libsoftphone.data;

/**
 * 账户节点常量（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：Account.ACCOUNT（账户 Xml 根节点名）、Account.USERNAME /
 * Account.HOST（childValue 键）、Account.Attributes.ID（账户 Id 属性）。
 */
public final class Account {

    /** 账户 Xml 根节点名 */
    public static final String ACCOUNT = "account";

    /** 用户名子节点键 */
    public static final String USERNAME = "username";

    /** 服务器主机子节点键 */
    public static final String HOST = "host";

    private Account() {
    }

    /** 账户 Xml 属性名 */
    public static final class Attributes {
        public static final String ID = "id";

        private Attributes() {
        }
    }
}
