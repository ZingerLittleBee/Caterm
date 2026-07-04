import Foundation
import ManagedKeyStore
import SessionStore
import SSHCommandBuilder

/// Private-key material the user supplied in a host form, before it has
/// been imported into managed storage. `nil` in an edit flow means "keep
/// the existing managed key".
public enum PendingKeyMaterial: Equatable, Sendable {
	/// A file the user picked (or typed). Bytes are read once at
	/// provision time and copied into managed storage; the path itself
	/// is never persisted (ADR 0003).
	case file(path: String)
	/// Key text the user pasted.
	case pasted(content: String)
}

public enum HostKeyProvisioningError: Error, Equatable {
	case unreadableFile(path: String)
	case emptyKey
}

/// Summary of the one-time launch migration from external key paths to
/// managed storage.
public struct KeyMigrationSummary: Equatable, Sendable {
	public var migrated = 0
	/// Hosts whose external key file could not be read — left untouched;
	/// `needsCredentialSetup` guides the user on next connect.
	public var skippedUnreadable = 0
	public var alreadyManaged = 0

	public init() {}
}

/// Imports private-key bytes into `ManagedKeyStore` and keeps host
/// credentials pointing inside managed storage — the only key reference
/// shape hosts may hold (ADR 0003). Sits above SessionStore and
/// ManagedKeyStore because SessionStore deliberately has no
/// ManagedKeyStore dependency (Plan C: callers write key bytes first).
@MainActor
public enum HostKeyProvisioner {

	/// Resolve pending material to raw key bytes.
	public static func keyBytes(from material: PendingKeyMaterial) throws -> Data {
		switch material {
		case let .file(path):
			let expanded = (path as NSString).expandingTildeInPath
			guard let bytes = FileManager.default.contents(atPath: expanded),
			      !bytes.isEmpty else {
				throw HostKeyProvisioningError.unreadableFile(path: path)
			}
			return bytes
		case let .pasted(content):
			let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { throw HostKeyProvisioningError.emptyKey }
			// Key parsers require the trailing newline PEM files carry.
			return Data((trimmed + "\n").utf8)
		}
	}

	/// Import `material` for `hostId` and persist the credential through
	/// SessionStore's Plan C entry point: managed-key write → credential
	/// update (+ passphrase Keychain write) → dirty=true → notification,
	/// so credential sync picks the new key up on its next cycle.
	public static func provision(
		material: PendingKeyMaterial,
		hasPassphrase: Bool,
		passphrase: String?,
		hostId: UUID,
		sessionStore: SessionStore,
		managedKeys: ManagedKeyStore
	) async throws {
		let bytes = try keyBytes(from: material)
		let target = try await managedKeys.write(hostId: hostId, bytes: bytes)
		try sessionStore.setHostCredentialMaterial(
			secrets: HostSecrets(
				passphrase: passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) },
				privateKeyBytes: bytes
			),
			credentialSource: .keyFile(keyPath: target.path, hasPassphrase: hasPassphrase),
			for: hostId
		)
	}

	/// One-time launch migration (ADR 0003): copy every `.keyFile` host's
	/// external key file into managed storage and rewrite `keyPath` via
	/// `setCredentialOnly` — which touches neither `updatedAt` nor
	/// `credentialMaterialDirty`, so the relocation triggers no sync push.
	/// Unreadable sources are left as-is (no data is ever deleted).
	@discardableResult
	public static func migrateExternalKeyPaths(
		sessionStore: SessionStore,
		managedKeys: ManagedKeyStore
	) async -> KeyMigrationSummary {
		var summary = KeyMigrationSummary()
		for host in sessionStore.hosts {
			guard case let .keyFile(path, hasPassphrase) = host.credential else { continue }
			let managedPath = managedKeys.path(hostId: host.id).path
			if path == managedPath {
				summary.alreadyManaged += 1
				continue
			}
			let expanded = (path as NSString).expandingTildeInPath
			guard let bytes = FileManager.default.contents(atPath: expanded),
			      !bytes.isEmpty else {
				summary.skippedUnreadable += 1
				continue
			}
			do {
				let target = try await managedKeys.write(hostId: host.id, bytes: bytes)
				try sessionStore.setCredentialOnly(
					.keyFile(keyPath: target.path, hasPassphrase: hasPassphrase),
					for: host.id
				)
				summary.migrated += 1
			} catch {
				summary.skippedUnreadable += 1
			}
		}
		return summary
	}
}
