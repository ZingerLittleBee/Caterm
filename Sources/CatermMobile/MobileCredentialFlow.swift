import Foundation
import KeychainStore
import SSHCommandBuilder
import SSHCredentialContract
import SwiftUI

public protocol MobileCredentialStoring: AnyObject {
	func set(account: String, secret: String) throws
	func get(
		account: String,
		interaction: KeychainReadInteraction
	) throws -> String
	func delete(account: String) throws
}

extension KeychainStore: MobileCredentialStoring {}

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
		SSHCredentialContract.account(hostID: id, kind: .password)
	}

	public static func keyPassphraseAccount(_ id: UUID) -> String {
		SSHCredentialContract.account(hostID: id, kind: .keyPassphrase)
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
public actor MobileCredentialWriter {
	public struct TransactionRollbackError: Error {
		public let originalError: any Error
		public let rollbackErrors: [any Error]
	}

	private enum StoredSecret {
		case missing
		case value(String)
	}

	public static let defaultService = SSHCredentialContract.keychainService

	private let storage: any MobileCredentialStoring

	public init(keychain: KeychainStore) {
		self.storage = keychain
	}

	init(storage: any MobileCredentialStoring) {
		self.storage = storage
	}

	public func apply(_ payload: MobileHostDraftPayload) throws {
		try apply(MobileCredentialPlan.operations(for: payload))
	}

	public func commitSave(
		_ payload: MobileHostDraftPayload,
		commit: @MainActor @Sendable () async throws -> Void
	) async throws {
		let accounts = Self.accounts(hostID: payload.host.id)
		let snapshot = try capture(accounts)
		do {
			try apply(MobileCredentialPlan.operations(for: payload))
			try await commit()
		} catch {
			try rollback(snapshot, originalError: error)
		}
	}

	public func commitDeletion(
		hostID: UUID,
		commit: @MainActor @Sendable () async throws -> Void
	) async throws {
		let accounts = Self.accounts(hostID: hostID)
		let snapshot = try capture(accounts)
		do {
			try apply(accounts.map(MobileCredentialOp.clear))
			try await commit()
		} catch {
			try rollback(snapshot, originalError: error)
		}
	}

	private func apply(_ operations: [MobileCredentialOp]) throws {
		for op in operations {
			switch op {
			case let .write(account, secret):
				try storage.set(account: account, secret: secret)
			case let .clear(account):
				do {
					try storage.delete(account: account)
				} catch KeychainError.notFound {
					continue
				}
			}
		}
	}

	/// Remove every secret for a host (called when the host is deleted).
	public func clearAll(hostId: UUID) throws {
		let accounts = Self.accounts(hostID: hostId)
		let snapshot = try capture(accounts)
		do {
			try apply(accounts.map(MobileCredentialOp.clear))
		} catch {
			try rollback(snapshot, originalError: error)
		}
	}

	private static func accounts(hostID: UUID) -> [String] {
		[
			MobileCredentialPlan.passwordAccount(hostID),
			MobileCredentialPlan.keyPassphraseAccount(hostID),
		]
	}

	private func capture(_ accounts: [String]) throws -> [String: StoredSecret] {
		var snapshot: [String: StoredSecret] = [:]
		for account in accounts {
			do {
				snapshot[account] = .value(try storage.get(
					account: account,
					interaction: .userInitiated
				))
			} catch KeychainError.notFound {
				snapshot[account] = .missing
			}
		}
		return snapshot
	}

	private func rollback(
		_ snapshot: [String: StoredSecret],
		originalError: any Error
	) throws -> Never {
		var rollbackErrors: [any Error] = []
		for account in snapshot.keys.sorted() {
			guard let secret = snapshot[account] else { continue }
			do {
				switch secret {
				case .missing:
					do {
						try storage.delete(account: account)
					} catch KeychainError.notFound {}
				case .value(let value):
					try storage.set(account: account, secret: value)
				}
			} catch {
				rollbackErrors.append(error)
			}
		}
		guard rollbackErrors.isEmpty else {
			throw TransactionRollbackError(
				originalError: originalError,
				rollbackErrors: rollbackErrors
			)
		}
		throw originalError
	}
}

/// Save command injected by `MobileRootView`: persists the host and its
/// credential material. When absent (array-backed previews/tests) the
/// shell falls back to in-memory binding mutation and drops secrets.
public struct MobileHostSaveAction {
	public let save: @MainActor (MobileHostDraftPayload) async -> Bool
	public let deleteHost: @MainActor (UUID) async -> Bool

	public init(
		save: @escaping @MainActor (MobileHostDraftPayload) async -> Bool,
		deleteHost: @escaping @MainActor (UUID) async -> Bool
	) {
		self.save = save
		self.deleteHost = deleteHost
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
