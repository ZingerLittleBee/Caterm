import CryptoKit
import Foundation
import Security

public actor KeychainSyncMasterKeyStore {
    public enum Error: Swift.Error, Equatable {
        case keychainOSError(OSStatus)
    }

    private let service: String
    private let synchronizable: Bool

    public init(
        service: String = "com.caterm.cloudkit-sync.masterKey",
        synchronizable: Bool = true
    ) {
        self.service = service
        self.synchronizable = synchronizable
    }

    public func loadAny() -> (keyID: String, key: SymmetricKey)? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String:      kSecMatchLimitOne,
            kSecReturnData as String:      true,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let id = dict[kSecAttrAccount as String] as? String else { return nil }
        return (id, SymmetricKey(data: data))
    }

    public func load(keyID: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     keyID,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String:      kSecMatchLimitOne,
            kSecReturnData as String:      true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    public func generate() throws -> (keyID: String, key: SymmetricKey) {
        let key = SymmetricKey(size: .bits256)
        let id = UUID().uuidString
        let bytes = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecAttrAccount as String:         id,
            kSecAttrSynchronizable as String:  synchronizable,
            kSecAttrAccessible as String:      kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String:           bytes,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.keychainOSError(status) }
        return (id, key)
    }

    public func remove(keyID: String) {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     keyID,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
