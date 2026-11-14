import Foundation
import Security

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "net.miniply.connection",
        kSecAttrAccount as String: "primary"
    ]

    static func load() -> Connection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        guard let connection = try? JSONDecoder().decode(Connection.self, from: data) else { return nil }
        // A Release build may inherit a connection saved by a Debug installation.
        return try? API.validate(address: connection.baseURL.absoluteString, token: connection.token)
    }

    static func save(_ connection: Connection) throws {
        let data = try JSONEncoder().encode(connection)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw MiniplyError.message(String(localized: "Zugang konnte nicht im Schlüsselbund gespeichert werden."))
            }
        } else if status != errSecSuccess {
            throw MiniplyError.message(String(localized: "Schlüsselbund ist nicht verfügbar (\(status))."))
        }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
