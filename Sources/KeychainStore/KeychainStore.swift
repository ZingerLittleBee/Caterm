import Foundation
import LocalAuthentication
import Security
import SSHCredentialContract

public enum KeychainError: Error, Equatable {
    case notFound
    case interactionNotAllowed
    case osStatus(OSStatus)
    case decodeFailed
    /// `deleteAll` could not delete one or more matched items. Carries the
    /// failing accounts so the caller can surface that secret material may
    /// still be on-device rather than silently reporting a clean reset.
    case partialDeleteFailure(failedAccounts: [String])
}

public enum KeychainReadInteraction: Equatable, Sendable {
    case userInitiated
    case nonInteractive
}

struct KeychainItemReadResult {
    let status: OSStatus
    let value: AnyObject?
}

protocol KeychainItemReading {
    func read(query: [String: Any]) -> KeychainItemReadResult
}

private struct SecurityKeychainItemReader: KeychainItemReading {
    func read(query: [String: Any]) -> KeychainItemReadResult {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return KeychainItemReadResult(status: status, value: result)
    }
}

public final class KeychainStore {
    public let service: String
    public let accessGroup: String?
    private let itemReader: any KeychainItemReading

    public convenience init(
        service: String = SSHCredentialContract.keychainService,
        accessGroup: String?
    ) {
        self.init(
            service: service,
            accessGroup: accessGroup,
            itemReader: SecurityKeychainItemReader()
        )
    }

    init(
        service: String,
        accessGroup: String?,
        itemReader: any KeychainItemReading
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.itemReader = itemReader
    }

    public func set(account: String, secret: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.decodeFailed }
        // Try update first, then add
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainError.osStatus(updateStatus) }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { throw KeychainError.osStatus(addStatus) }
    }

    public func get(
        account: String,
        interaction: KeychainReadInteraction = .userInitiated
    ) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if interaction == .nonInteractive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let result = itemReader.read(query: query)
        let status = result.status
        if status == errSecItemNotFound { throw KeychainError.notFound }
        if status == errSecInteractionNotAllowed {
            throw KeychainError.interactionNotAllowed
        }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
        guard let data = result.value as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed
        }
        return secret
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
    }

    public func deleteAll(prefix: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
        guard let items = result as? [[String: Any]] else { return }
        var failed: [String] = []
        for item in items {
            guard let acct = item[kSecAttrAccount as String] as? String,
                  acct.hasPrefix(prefix) else { continue }
            do {
                try delete(account: acct)
            } catch KeychainError.notFound {
                // Already gone — the desired end state, not a failure.
            } catch {
                // A real delete failure means secret material may still be
                // on-device; collect it instead of silently swallowing so
                // the caller doesn't report a clean reset.
                failed.append(acct)
            }
        }
        if !failed.isEmpty {
            throw KeychainError.partialDeleteFailure(failedAccounts: failed)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
}
