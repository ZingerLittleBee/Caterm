import Combine
import Foundation

public enum CredentialIdentityStoreError: Error, Equatable {
	case duplicateIdentityID(UUID)
	case duplicateMaterialID(CredentialMaterialID)
	case identityNotFound(UUID)
	case identityInUse(identityID: UUID, hostIDs: Set<UUID>)
	case unsupportedEnvelopeVersion(found: Int, supported: Int)
	case readFailed(String)
	case writeFailed(String)
}

private struct CredentialIdentitiesEnvelope: Codable {
	let schemaVersion: Int
	let identities: [CredentialIdentity]
	let locallyDirtyIdentityIDs: [UUID]
	let pendingDeletedIdentityIDs: [UUID]
}

@MainActor
public final class CredentialIdentityStore: ObservableObject {
	public static let envelopeSchemaVersion = 1

	@Published public private(set) var identities: [CredentialIdentity] = []
	@Published public private(set) var locallyDirtyIdentityIDs: Set<UUID> = []
	@Published public private(set) var pendingDeletedIdentityIDs: Set<UUID> = []

	private let fileURL: URL
	private let now: () -> Date

	public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
		self.fileURL = fileURL
		self.now = now
	}

	public func load() throws {
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			return
		}
		do {
			let data = try Data(contentsOf: fileURL)
			let envelope = try JSONDecoder().decode(
				CredentialIdentitiesEnvelope.self,
				from: data
			)
			guard envelope.schemaVersion == Self.envelopeSchemaVersion else {
				throw CredentialIdentityStoreError.unsupportedEnvelopeVersion(
					found: envelope.schemaVersion,
					supported: Self.envelopeSchemaVersion
				)
			}
			try Self.validate(envelope.identities)
			identities = envelope.identities
			locallyDirtyIdentityIDs = Set(envelope.locallyDirtyIdentityIDs)
			pendingDeletedIdentityIDs = Set(envelope.pendingDeletedIdentityIDs)
		} catch let error as CredentialIdentityStoreError {
			throw error
		} catch {
			throw CredentialIdentityStoreError.readFailed(
				error.localizedDescription
			)
		}
	}

	public func identity(id: UUID) -> CredentialIdentity? {
		identities.first { $0.id == id }
	}

	public func upsert(_ identity: CredentialIdentity) throws {
		var candidate = try identity.validated()
		try persistMutation {
			if let index = identities.firstIndex(where: {
				$0.id == candidate.id
			}) {
				let existing = identities[index]
				candidate.createdAt = existing.createdAt
				candidate.updatedAt = now()
				candidate.revision = existing.revision + 1
				identities[index] = candidate
			} else {
				identities.append(candidate)
			}
			locallyDirtyIdentityIDs.insert(candidate.id)
			pendingDeletedIdentityIDs.remove(candidate.id)
		}
	}

	public func delete(
		id: UUID,
		assignedHostIDs: Set<UUID> = []
	) throws {
		guard assignedHostIDs.isEmpty else {
			throw CredentialIdentityStoreError.identityInUse(
				identityID: id,
				hostIDs: assignedHostIDs
			)
		}
		guard identities.contains(where: { $0.id == id }) else {
			throw CredentialIdentityStoreError.identityNotFound(id)
		}
		try persistMutation {
			identities.removeAll { $0.id == id }
			locallyDirtyIdentityIDs.remove(id)
			pendingDeletedIdentityIDs.insert(id)
		}
	}

	@discardableResult
	public func applyRemote(_ identity: CredentialIdentity) throws -> Bool {
		let candidate = try identity.validated()
		var applied = false
		try persistMutation {
			if let index = identities.firstIndex(where: {
				$0.id == candidate.id
			}) {
				let local = identities[index]
				guard Self.remoteWins(local: local, remote: candidate) else {
					return
				}
				identities[index] = candidate
			} else {
				identities.append(candidate)
			}
			locallyDirtyIdentityIDs.remove(candidate.id)
			pendingDeletedIdentityIDs.remove(candidate.id)
			applied = true
		}
		return applied
	}

	public func applyRemoteTombstone(id: UUID) throws {
		try persistMutation {
			identities.removeAll { $0.id == id }
			locallyDirtyIdentityIDs.remove(id)
			pendingDeletedIdentityIDs.remove(id)
		}
	}

	public func acknowledgePush(id: UUID, serverID: String?) throws {
		guard let index = identities.firstIndex(where: { $0.id == id }) else {
			throw CredentialIdentityStoreError.identityNotFound(id)
		}
		try persistMutation {
			identities[index].serverID = serverID ?? identities[index].serverID
			locallyDirtyIdentityIDs.remove(id)
		}
	}

	public func acknowledgeDeletion(id: UUID) throws {
		try persistMutation {
			pendingDeletedIdentityIDs.remove(id)
		}
	}

	private static func remoteWins(
		local: CredentialIdentity,
		remote: CredentialIdentity
	) -> Bool {
		if remote.revision != local.revision {
			return remote.revision > local.revision
		}
		if remote.updatedAt != local.updatedAt {
			return remote.updatedAt > local.updatedAt
		}
		return true
	}

	private static func validate(
		_ identities: [CredentialIdentity]
	) throws {
		var identityIDs: Set<UUID> = []
		var materialIDs: Set<CredentialMaterialID> = []
		for identity in identities {
			_ = try identity.validated()
			guard identityIDs.insert(identity.id).inserted else {
				throw CredentialIdentityStoreError.duplicateIdentityID(
					identity.id
				)
			}
			guard materialIDs.insert(identity.source.materialID).inserted else {
				throw CredentialIdentityStoreError.duplicateMaterialID(
					identity.source.materialID
				)
			}
		}
	}

	private func persistMutation(_ mutation: () throws -> Void) throws {
		let previousIdentities = identities
		let previousDirty = locallyDirtyIdentityIDs
		let previousDeleted = pendingDeletedIdentityIDs
		do {
			try mutation()
			try Self.validate(identities)
			try writeState()
		} catch {
			identities = previousIdentities
			locallyDirtyIdentityIDs = previousDirty
			pendingDeletedIdentityIDs = previousDeleted
			throw error
		}
	}

	private func writeState() throws {
		let envelope = CredentialIdentitiesEnvelope(
			schemaVersion: Self.envelopeSchemaVersion,
			identities: identities,
			locallyDirtyIdentityIDs: locallyDirtyIdentityIDs.sorted {
				$0.uuidString < $1.uuidString
			},
			pendingDeletedIdentityIDs: pendingDeletedIdentityIDs.sorted {
				$0.uuidString < $1.uuidString
			}
		)
		let data = try JSONEncoder().encode(envelope)
		let directory = fileURL.deletingLastPathComponent()
		let temporaryURL = directory.appendingPathComponent(
			".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
		)
		do {
			try FileManager.default.createDirectory(
				at: directory,
				withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700]
			)
			try data.write(to: temporaryURL, options: [.atomic])
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o600],
				ofItemAtPath: temporaryURL.path
			)
			if FileManager.default.fileExists(atPath: fileURL.path) {
				_ = try FileManager.default.replaceItemAt(
					fileURL,
					withItemAt: temporaryURL
				)
			} else {
				try FileManager.default.moveItem(
					at: temporaryURL,
					to: fileURL
				)
			}
		} catch {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw CredentialIdentityStoreError.writeFailed(
				error.localizedDescription
			)
		}
	}
}
