//
//  CompatKeychain.swift
//  CompatFW
//
//  SIP 密码 Keychain 存取(对齐 dev-webrtc 219f069b 整改语义;compat 无
//  三方依赖,Security 原生实现)。快照 plist 可被备份提取;Keychain
//  ThisDeviceOnly 硬件加密、不进备份/不同步 iCloud。
//

import Foundation
import Security

enum CompatKeychain {

    /// 独立 service(与 App 各自 Keychain 域隔离)。AlwaysThisDeviceOnly:
    /// 任何时刻可读——覆盖「重启后未首次解锁」的杀进程 VoIP 唤醒注册场景
    /// (AfterFirstUnlock 在该窗口读不到,唤醒注册必失败)
    private static let sipAuthService = "com.yeastar.compat.sip-auth"
    private static let sipPasswordKey = "sipPassword"

    /// @return false = 写失败(Keychain 异常;下次冷启动注册将无凭证,日志已告警)
    @discardableResult
    static func setSipPassword(_ password: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sipAuthService,
            kSecAttrAccount as String: sipPasswordKey,
        ]
        // 先 Update(已有条目),NotFound 再 Add(条目不含 accessible 更新面)
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAlwaysThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("[compat] keychain save password failed (status=%ld)", status)
            return false
        }
        return true
    }

    /// @return nil = Keychain 无密码(未登录/已登出/系统异常),调用方按无凭证放弃
    static func sipPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sipAuthService,
            kSecAttrAccount as String: sipPasswordKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// 登出双清之一(UserDefaults 快照键 + 此处;键不存在即目标态,静默)
    static func clearSipPassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sipAuthService,
            kSecAttrAccount as String: sipPasswordKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
