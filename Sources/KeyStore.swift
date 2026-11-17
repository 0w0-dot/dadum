import Foundation
import Security

/// Claude API 키를 키체인에 둔다. 파일이나 설정에는 남기지 않는다.
enum KeyStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.0w0-dot.dadum",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
