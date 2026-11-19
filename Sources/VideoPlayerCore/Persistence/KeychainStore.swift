import Foundation
import Security

/// API 金鑰存在 macOS Keychain，不寫入明文檔案
public enum KeychainStore {
    public static let service = "com.benzhub.RushVideoPlayer"

    public enum Key: String, Sendable {
        case anthropicAPIKey = "anthropic-api-key"
        case notionToken = "notion-token"
    }

    public static func get(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 傳入空字串會刪除
    @discardableResult
    public static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
