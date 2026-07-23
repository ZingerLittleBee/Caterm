import Combine
import Foundation

private let credentialIdentityEnvelopeSchemaVersion = 1

public enum CredentialIdentityStoreError: Error, Equatable {
	case duplicateIdentityID(UUID)
	case duplicateMaterialID(CredentialMaterialID)
	case identityNotFound(UUID)
	case identityInUse(identityID: UUID, hostIDs: Set<UUID>)
	case identityDeletionInProgress(UUID)
	case unsupportedEnvelopeVersion(found: Int, supported: Int)
	case readFailed(String)
	case writeFailed(String)
}

public struct CredentialIdentityStoreSnapshot: Equatable, Sendable {
	public let identities: [CredentialIdentity]
	public let locallyDirtyIdentityIDs: Set<UUID>
	public let pendingDeletedIdentityIDs: Set<UUID>

	public init(
		identities: [CredentialIdentity],
		locallyDirtyIdentityIDs: Set<UUID>,
		pendingDeletedIdentityIDs: Set<UUID>
	) {
		self.identities = identities
		self.locallyDirtyIdentityIDs = locallyDirtyIdentityIDs
		self.pendingDeletedIdentityIDs = pendingDeletedIdentityIDs
	}
}

private struct CredentialIdentitiesEnvelope: Codable, Sendable {
	let schemaVersion: Int
	var identities: [CredentialIdentity]
	var locallyDirtyIdentityIDs: Set<UUID>
	var pendingDeletedIdentityIDs: Set<UUID>

	init(
		schemaVersion: Int,
		identities: [CredentialIdentity],
		locallyDirtyIdentityIDs: Set<UUID>,
		pendingDeletedIdentityIDs: Set<UUID>
	) {
		self.schemaVersion = schemaVersion
		self.identities = identities
		self.locallyDirtyIdentityIDs = locallyDirtyIdentityIDs
		self.pendingDeletedIdentityIDs = pendingDeletedIdentityIDs
	}

	private enum CodingKeys: String, CodingKey {
		case schemaVersion
		case identities
		case locallyDirtyIdentityIDs
		case pendingDeletedIdentityIDs
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		identities = try container.decode(
			[CredentialIdentity].self,
			forKey: .identities
		)
		locallyDirtyIdentityIDs = Set(try container.decode(
			[UUID].self,
			forKey: .locallyDirtyIdentityIDs
		))
		pendingDeletedIdentityIDs = Set(try container.decode(
			[UUID].self,
			forKey: .pendingDeletedIdentityIDs
		))
	}

	func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(schemaVersion, forKey: .schemaVersion)
		try container.encode(identities, forKey: .identities)
		try container.encode(
			locallyDirtyIdentityIDs.sorted {
				$0.uuidString < $1.uuidString
			},
			forKey: .locallyDirtyIdentityIDs
		)
		try container.encode(
			pendingDeletedIdentityIDs.sorted {
				$0.uuidString < $1.uuidString
			},
			forKey: .pendingDeletedIdentityIDs
		)
	}
}

private actor CredentialIdentityPersistence {
	private let fileURL: URL
	private let now: @Sendable () -> Date
	private var isLoaded = false
	private var state = CredentialIdentitiesEnvelope(
		schemaVersion: credentialIdentityEnvelopeSchemaVersion,
		identities: [],
		locallyDirtyIdentityIDs: [],
		pendingDeletedIdentityIDs: []
	)

	init(fileURL: URL, now: @escaping @Sendable () -> Date) {
		self.fileURL = fileURL
		self.now = now
	}

	func load() throws -> CredentialIdentitiesEnvelope {
		if isLoaded {
			return state
		}
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			isLoaded = true
			return state
		}
		do {
			let data = try Data(contentsOf: fileURL)
			let envelope = try JSONDecoder().decode(
				CredentialIdentitiesEnvelope.self,
				from: data
			)
			guard envelope.schemaVersion
				== credentialIdentityEnvelopeSchemaVersion else {
				throw CredentialIdentityStoreError.unsupportedEnvelopeVersion(
					found: envelope.schemaVersion,
					supported: credentialIdentityEnvelopeSchemaVersion
				)
			}
			try Self.validate(envelope.identities)
			state = envelope
			isLoaded = true
			return state
		} catch let error as CredentialIdentityStoreError {
			throw error
		} catch {
			throw CredentialIdentityStoreError.readFailed(
				error.localizedDescription
			)
		}
	}

	func upsert(
		_ identity: CredentialIdentity
	) throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		var candidate = try identity.validated()
		return try persistMutation {
			if let index = state.identities.firstIndex(where: {
				$0.id == candidate.id
			}) {
				let existing = state.identities[index]
				candidate.createdAt = existing.createdAt
				candidate.updatedAt = now()
				candidate.revision = existing.revision + 1
				state.identities[index] = candidate
			} else {
				state.identities.append(candidate)
			}
			state.locallyDirtyIdentityIDs.insert(candidate.id)
			state.pendingDeletedIdentityIDs.remove(candidate.id)
		}
	}

	func delete(
		id: UUID,
		assignedHostIDs: Set<UUID>
	) throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		guard assignedHostIDs.isEmpty else {
			throw CredentialIdentityStoreError.identityInUse(
				identityID: id,
				hostIDs: assignedHostIDs
			)
		}
		guard state.identities.contains(where: { $0.id == id }) else {
			throw CredentialIdentityStoreError.identityNotFound(id)
		}
		return try persistMutation {
			state.identities.removeAll { $0.id == id }
			state.locallyDirtyIdentityIDs.remove(id)
			state.pendingDeletedIdentityIDs.insert(id)
		}
	}

	func applyRemote(
		_ identity: CredentialIdentity
	) throws -> (CredentialIdentitiesEnvelope, Bool) {
		_ = try load()
		let candidate = try identity.validated()
		var applied = false
		let updated = try persistMutation {
			if let index = state.identities.firstIndex(where: {
				$0.id == candidate.id
			}) {
				let local = state.identities[index]
				guard Self.remoteWins(local: local, remote: candidate) else {
					return
				}
				state.identities[index] = candidate
			} else {
				state.identities.append(candidate)
			}
			state.locallyDirtyIdentityIDs.remove(candidate.id)
			state.pendingDeletedIdentityIDs.remove(candidate.id)
			applied = true
		}
		return (updated, applied)
	}

	func applyRemoteTombstone(
		id: UUID
	) throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		return try persistMutation {
			state.identities.removeAll { $0.id == id }
			state.locallyDirtyIdentityIDs.remove(id)
			state.pendingDeletedIdentityIDs.remove(id)
		}
	}

	func acknowledgePush(
		id: UUID,
		serverID: String?
	) throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		guard let index = state.identities.firstIndex(where: {
			$0.id == id
		}) else {
			throw CredentialIdentityStoreError.identityNotFound(id)
		}
		return try persistMutation {
			state.identities[index].serverID =
				serverID ?? state.identities[index].serverID
			state.locallyDirtyIdentityIDs.remove(id)
		}
	}

	func acknowledgeDeletion(id: UUID) throws
		-> CredentialIdentitiesEnvelope {
		_ = try load()
		return try persistMutation {
			state.pendingDeletedIdentityIDs.remove(id)
		}
	}

	func resetForAccountChange() throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		return try persistMutation {
			state.identities.removeAll()
			state.locallyDirtyIdentityIDs.removeAll()
			state.pendingDeletedIdentityIDs.removeAll()
		}
	}

	func restore(
		_ snapshot: CredentialIdentityStoreSnapshot
	) throws -> CredentialIdentitiesEnvelope {
		_ = try load()
		let restored = CredentialIdentitiesEnvelope(
			schemaVersion: credentialIdentityEnvelopeSchemaVersion,
			identities: snapshot.identities,
			locallyDirtyIdentityIDs: snapshot.locallyDirtyIdentityIDs,
			pendingDeletedIdentityIDs: snapshot.pendingDeletedIdentityIDs
		)
		try Self.validate(restored.identities)
		let previous = state
		state = restored
		do {
			try writeState()
			return state
		} catch {
			state = previous
			throw error
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

	private func persistMutation(
		_ mutation: () throws -> Void
	) throws -> CredentialIdentitiesEnvelope {
		let previous = state
		do {
			try mutation()
			try Self.validate(state.identities)
			try writeState()
			return state
		} catch {
			state = previous
			throw error
		}
	}

	private func writeState() throws {
		let data = try JSONEncoder().encode(state)
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
			let persistenceError = error
			do {
				if FileManager.default.fileExists(
					atPath: temporaryURL.path
				) {
					try FileManager.default.removeItem(at: temporaryURL)
				}
			} catch {
				throw CredentialIdentityStoreError.writeFailed(
					"Persistence failed: "
						+ persistenceError.localizedDescription
						+ "; temporary-file cleanup failed: "
						+ error.localizedDescription
				)
			}
			throw CredentialIdentityStoreError.writeFailed(
				persistenceError.localizedDescription
			)
		}
	}
}

private actor CredentialIdentityTransactionGate {
	private var isHeld = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var contentionObservers: [CheckedContinuation<Void, Never>] = []

	func acquire() async {
		guard isHeld else {
			isHeld = true
			return
		}
		await withCheckedContinuation { continuation in
			waiters.append(continuation)
			let observers = contentionObservers
			contentionObservers.removeAll()
			for observer in observers {
				observer.resume()
			}
		}
	}

	func release() {
		guard !waiters.isEmpty else {
			isHeld = false
			return
		}
		waiters.removeFirst().resume()
	}

	func waitUntilContended() async {
		guard waiters.isEmpty else { return }
		await withCheckedContinuation { continuation in
			contentionObservers.append(continuation)
		}
	}
}

@MainActor
public final class CredentialIdentityStore: ObservableObject {
	public nonisolated static let envelopeSchemaVersion =
		credentialIdentityEnvelopeSchemaVersion

	@Published public private(set) var identities: [CredentialIdentity] = []
	@Published public private(set) var locallyDirtyIdentityIDs: Set<UUID> = []
	@Published public private(set) var pendingDeletedIdentityIDs: Set<UUID> = []

	private let persistence: CredentialIdentityPersistence
	private let transactionGate = CredentialIdentityTransactionGate()
	private var deletionReservations: Set<UUID> = []

	public init(
		fileURL: URL,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		persistence = CredentialIdentityPersistence(fileURL: fileURL, now: now)
	}

	public func load() async throws {
		publish(try await persistence.load())
	}

	public func identity(id: UUID) -> CredentialIdentity? {
		identities.first { $0.id == id }
	}

	public func wouldApplyRemote(_ remote: CredentialIdentity) -> Bool {
		guard let local = identity(id: remote.id) else {
			return true
		}
		if remote.revision != local.revision {
			return remote.revision > local.revision
		}
		if remote.updatedAt != local.updatedAt {
			return remote.updatedAt > local.updatedAt
		}
		return true
	}

	public func upsert(_ identity: CredentialIdentity) async throws {
		publish(try await persistence.upsert(identity))
	}

	public func delete(
		id: UUID,
		assignedHostIDs: Set<UUID> = []
	) async throws {
		publish(try await persistence.delete(
			id: id,
			assignedHostIDs: assignedHostIDs
		))
	}

	@discardableResult
	public func applyRemote(_ identity: CredentialIdentity) async throws
		-> Bool {
		let (state, applied) = try await persistence.applyRemote(identity)
		publish(state)
		return applied
	}

	public func applyRemoteTombstone(id: UUID) async throws {
		publish(try await persistence.applyRemoteTombstone(id: id))
	}

	public func acknowledgePush(
		id: UUID,
		serverID: String?
	) async throws {
		publish(try await persistence.acknowledgePush(
			id: id,
			serverID: serverID
		))
	}

	public func acknowledgeDeletion(id: UUID) async throws {
		publish(try await persistence.acknowledgeDeletion(id: id))
	}

	/// Clears account-scoped identities without creating CloudKit tombstones.
	///
	/// Account changes must not delete records owned by the previous account.
	/// The caller is responsible for removing local secret material first.
	public func resetForAccountChange() async throws {
		publish(try await persistence.resetForAccountChange())
	}

	public func snapshot() -> CredentialIdentityStoreSnapshot {
		CredentialIdentityStoreSnapshot(
			identities: identities,
			locallyDirtyIdentityIDs: locallyDirtyIdentityIDs,
			pendingDeletedIdentityIDs: pendingDeletedIdentityIDs
		)
	}

	public func restore(
		_ snapshot: CredentialIdentityStoreSnapshot
	) async throws {
		publish(try await persistence.restore(snapshot))
	}

	public func withTransaction<T>(
		_ operation: @MainActor () async throws -> T
	) async throws -> T {
		await transactionGate.acquire()
		do {
			let result = try await operation()
			await transactionGate.release()
			return result
		} catch {
			await transactionGate.release()
			throw error
		}
	}

	func waitUntilTransactionIsContended() async {
		await transactionGate.waitUntilContended()
	}

	public func validateAssignment(identityID: UUID) throws {
		guard !deletionReservations.contains(identityID) else {
			throw CredentialIdentityStoreError.identityDeletionInProgress(
				identityID
			)
		}
		guard identity(id: identityID) != nil else {
			throw CredentialIdentityStoreError.identityNotFound(identityID)
		}
	}

	public func withDeletionReservation<T>(
		id: UUID,
		_ operation: @MainActor () async throws -> T
	) async throws -> T {
		guard deletionReservations.insert(id).inserted else {
			throw CredentialIdentityStoreError.identityDeletionInProgress(id)
		}
		defer { deletionReservations.remove(id) }
		return try await operation()
	}

	private func publish(_ state: CredentialIdentitiesEnvelope) {
		identities = state.identities
		locallyDirtyIdentityIDs = state.locallyDirtyIdentityIDs
		pendingDeletedIdentityIDs = state.pendingDeletedIdentityIDs
	}
}
