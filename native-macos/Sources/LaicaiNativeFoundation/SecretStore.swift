import Foundation
import Security

public enum SecretStore {
    private static var service: String { LaicaiStoragePaths.keychainService }
    private static let prefix = "keychain:"

    public static func reference(for scope: String, id: UUID, field: String) -> String {
        "\(prefix)\(scope):\(id.uuidString):\(field)"
    }

    public static func stagedReference(for scope: String, id: UUID, field: String) -> String {
        reference(for: scope, id: id, field: "\(field):\(UUID().uuidString)")
    }

    public static func isReference(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    public static func resolve(_ value: String) -> String {
        guard isReference(value) else { return value }
        return read(account: String(value.dropFirst(prefix.count))) ?? ""
    }

    @discardableResult
    public static func save(_ secret: String, reference: String) -> Bool {
        guard isReference(reference) else { return false }
        let account = String(reference.dropFirst(prefix.count))
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(reference: String) -> Bool {
        guard isReference(reference) else { return false }
        let account = String(reference.dropFirst(prefix.count))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
