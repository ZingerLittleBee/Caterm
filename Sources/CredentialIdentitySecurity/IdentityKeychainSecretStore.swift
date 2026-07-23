import Foundation
import Security

public enum IdentityKeychainError: Error, Equatable {
	case notFound
	case interactionNotAllowed
	case unexpectedResult
	case osStatus(OSStatus)
}

public protocol IdentitySecretStoring: Sendable {
	func read(account: String) throws -> Data?
	func write(_ data: Data, account: String) throws
	func delete(account: String) throws
}

public protocol IdentityRuntimeSecretScavenging: Sendable {
	func deleteAll(accountPrefix: String) throws
}

public final class IdentityKeychainSecretStore: IdentitySecretStoring,
	IdentityRuntimeSecretScavenging, @unchecked Sendable {
	private let service: String
	private let accessGroup: String?

	public init(
		service: String = CredentialIdentityKeychainContract.service,
		accessGroup: String? = nil
	) {
		self.service = service
		self.accessGroup = accessGroup
	}

	public func read(account: String) throws -> Data? {
		var query = baseQuery(account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let data = result as? Data else {
				throw IdentityKeychainError.unexpectedResult
			}
			return data
		case errSecItemNotFound:
			return nil
		case errSecInteractionNotAllowed:
			throw IdentityKeychainError.interactionNotAllowed
		default:
			throw IdentityKeychainError.osStatus(status)
		}
	}

	public func write(_ data: Data, account: String) throws {
		let query = baseQuery(account: account)
		let updateStatus = SecItemUpdate(
			query as CFDictionary,
			[kSecValueData as String: data] as CFDictionary
		)
		switch updateStatus {
		case errSecSuccess:
			return
		case errSecItemNotFound:
			var addQuery = query
			addQuery[kSecValueData as String] = data
			addQuery[kSecAttrAccessible as String] =
				kSecAttrAccessibleWhenUnlockedThisDeviceOnly
			let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
			guard addStatus == errSecSuccess else {
				throw IdentityKeychainError.osStatus(addStatus)
			}
		case errSecInteractionNotAllowed:
			throw IdentityKeychainError.interactionNotAllowed
		default:
			throw IdentityKeychainError.osStatus(updateStatus)
		}
	}

	public func delete(account: String) throws {
		let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			if status == errSecInteractionNotAllowed {
				throw IdentityKeychainError.interactionNotAllowed
			}
			throw IdentityKeychainError.osStatus(status)
		}
	}

	public func deleteAll(accountPrefix: String) throws {
		var query = baseServiceQuery()
		query[kSecReturnAttributes as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitAll
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status != errSecItemNotFound else { return }
		guard status == errSecSuccess else {
			if status == errSecInteractionNotAllowed {
				throw IdentityKeychainError.interactionNotAllowed
			}
			throw IdentityKeychainError.osStatus(status)
		}
		guard let items = result as? [[String: Any]] else {
			throw IdentityKeychainError.unexpectedResult
		}
		for item in items {
			guard let account = item[kSecAttrAccount as String] as? String,
			      account.hasPrefix(accountPrefix) else {
				continue
			}
			try delete(account: account)
		}
	}

	private func baseQuery(account: String) -> [String: Any] {
		var query = baseServiceQuery()
		query[kSecAttrAccount as String] = account
		return query
	}

	private func baseServiceQuery() -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
		]
		if let accessGroup {
			query[kSecAttrAccessGroup as String] = accessGroup
		}
		#if os(macOS)
		query[kSecUseDataProtectionKeychain as String] = true
		#endif
		return query
	}
}
