import Foundation
import Security

/// Device tokens, kept in the login keychain. Only this app can read them back without a prompt.
enum Keychain {
    static func token(service: String, account: String) -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false when the keychain refused it.
    @discardableResult
    static func setToken(_ token: String, service: String, account: String, label: String) -> Bool {
        let data = Data(token.utf8)
        let query = Self.query(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
