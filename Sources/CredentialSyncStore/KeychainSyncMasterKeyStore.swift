import CryptoKit
import Foundation
import os
import Security

struct SyncMasterKeyReadResult {
    let status: OSStatus
    let value: AnyObject?
}

protocol SyncMasterKeyReading: Sendable {
    func read(query: [String: Any]) -> SyncMasterKeyReadResult
}

private struct SecuritySyncMasterKeyReader: SyncMasterKeyReading {
    func read(query: [String: Any]) -> SyncMasterKeyReadResult {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return SyncMasterKeyReadResult(status: status, value: result)
    }
}

public actor KeychainSyncMasterKeyStore {
    public enum Error: Swift.Error, Equatable {
        case keychainOSError(OSStatus)
    }

    private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")
    private let service: String
    private let synchronizable: Bool
    private let reader: any SyncMasterKeyReading

    public init(
        service: String = "com.caterm.cloudkit-sync.masterKey",
        synchronizable: Bool = true
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.reader = SecuritySyncMasterKeyReader()
    }

    init(
        service: String,
        synchronizable: Bool,
        reader: any SyncMasterKeyReading
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.reader = reader
    }

    /// Strict lookup used by production synchronization. Absence is the only
    /// nil result; locked Keychain and entitlement failures remain errors.
    public func lookupAny() throws -> (keyID: String, key: SymmetricKey)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        let result = reader.read(query: query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw Error.keychainOSError(result.status)
        }
        guard let dict = result.value as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let id = dict[kSecAttrAccount as String] as? String else {
            throw Error.keychainOSError(errSecDecode)
        }
        return (id, SymmetricKey(data: data))
    }

    public func lookup(keyID: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        let result = reader.read(query: query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw Error.keychainOSError(result.status)
        }
        guard let data = result.value as? Data else {
            throw Error.keychainOSError(errSecDecode)
        }
        return SymmetricKey(data: data)
    }

    public func loadAny() -> (keyID: String, key: SymmetricKey)? {
        do {
            return try lookupAny()
        } catch let Error.keychainOSError(status) {
            Self.log.error(
                "loadAny: keychain read failed: OSStatus=\(status, privacy: .public)"
            )
            return nil
        } catch {
            return nil
        }
    }

    public func load(keyID: String) -> SymmetricKey? {
        do {
            return try lookup(keyID: keyID)
        } catch let Error.keychainOSError(status) {
            Self.log.error(
                "load: keychain read failed: OSStatus=\(status, privacy: .public)"
            )
            return nil
        } catch {
            return nil
        }
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
