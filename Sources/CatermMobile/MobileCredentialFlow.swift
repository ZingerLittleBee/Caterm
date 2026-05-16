import Foundation
import KeychainStore
import SSHCommandBuilder
import SwiftUI

/// A single keychain mutation derived from a saved host draft.
public enum MobileCredentialOp: Equatable {
	case write(account: String, secret: String)
	case clear(account: String)
}

/// Pure decision: given a built host + optional secret, what keychain
/// writes/clears keep credential material consistent. Account names mirror
/// the macOS convention (`<hostId>.password` / `<hostId>.keyPassphrase`,
/// service `com.caterm.host`) so desktop and CloudKit read the same items.
public enum MobileCredentialPlan {
	public static func passwordAccount(_ id: UUID) -> String {
		"\(id.uuidString).password"
	}

	public static func keyPassphraseAccount(_ id: UUID) -> String {
		"\(id.uuidString).keyPassphrase"
	}

	public static func operations(
		for payload: MobileHostDraftPayload
	) -> [MobileCredentialOp] {
		let id = payload.host.id
		let pw = passwordAccount(id)
		let pp = keyPassphraseAccount(id)

		switch payload.host.credential {
		case .password:
			// Blank-on-edit (secret == nil) preserves the stored password;
			// never clear the password account here.
			var ops: [MobileCredentialOp] = [.clear(account: pp)]
			if let secret = payload.secret {
				ops.append(.write(account: pw, secret: secret))
			}
			return ops
		case .keyFile:
			var ops: [MobileCredentialOp] = [.clear(account: pw)]
			if let secret = payload.secret {
				ops.append(.write(account: pp, secret: secret))
			}
			return ops
		case .agent:
			return [.clear(account: pw), .clear(account: pp)]
		}
	}
}

/// Applies a `MobileCredentialPlan` to a keychain. Clears are idempotent:
/// removing an account that was never written is not an error.
@MainActor
public struct MobileCredentialWriter {
	public static let defaultService = "com.caterm.host"

	private let keychain: KeychainStore

	public init(keychain: KeychainStore) {
		self.keychain = keychain
	}

	public func apply(_ payload: MobileHostDraftPayload) throws {
		for op in MobileCredentialPlan.operations(for: payload) {
			switch op {
			case let .write(account, secret):
				try keychain.set(account: account, secret: secret)
			case let .clear(account):
				do {
					try keychain.delete(account: account)
				} catch KeychainError.notFound {
					continue
				}
			}
		}
	}

	/// Remove every secret for a host (called when the host is deleted).
	public func clearAll(hostId: UUID) {
		try? keychain.deleteAll(prefix: "\(hostId.uuidString).")
	}
}

/// Save command injected by `MobileRootView`: persists the host and its
/// credential material. When absent (array-backed previews/tests) the
/// shell falls back to in-memory binding mutation and drops secrets.
public struct MobileHostSaveAction {
	public let save: (MobileHostDraftPayload) -> Void
	public let deleteCredentials: (UUID) -> Void

	public init(
		save: @escaping (MobileHostDraftPayload) -> Void,
		deleteCredentials: @escaping (UUID) -> Void
	) {
		self.save = save
		self.deleteCredentials = deleteCredentials
	}
}

private struct MobileHostSaveActionKey: EnvironmentKey {
	static let defaultValue: MobileHostSaveAction? = nil
}

extension EnvironmentValues {
	public var mobileHostSave: MobileHostSaveAction? {
		get { self[MobileHostSaveActionKey.self] }
		set { self[MobileHostSaveActionKey.self] = newValue }
	}
}
