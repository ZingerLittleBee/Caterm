import Foundation
import HostRepositoryCore
import SSHCommandBuilder

/// Serializes every saved-Host and deletion-outbox file transaction away from
/// the UI actor. The actor owns the authoritative persisted snapshot; callers
/// publish a returned snapshot only after its disk transaction succeeds.
actor SessionHostPersistence {
	struct DeletionRollbackError: Error {
		let originalError: any Error
		let rollbackErrors: [any Error]
	}

	enum MutationError: Error, Equatable {
		case staleSnapshot(expected: UInt64, actual: UInt64)
	}

	struct Snapshot: Sendable {
		let hosts: [SSHHost]
		let revision: UInt64
	}

	private let hostsURL: URL
	private var hosts: [SSHHost] = []
	private var deletionOutbox: HostDeletionOutbox?
	private var revision: UInt64 = 0
	private var isLoaded = false

	init(hostsURL: URL, initialHosts: [SSHHost]? = nil) {
		self.hostsURL = hostsURL
		if let initialHosts {
			hosts = initialHosts
			isLoaded = true
		}
	}

	func prepare() throws -> Snapshot {
		try ensureLoaded()
		return currentSnapshot
	}

	func mutate(
		expectedRevision: UInt64? = nil,
		_ transform: @Sendable (inout [SSHHost]) throws -> Void
	) throws -> Snapshot {
		try ensureLoaded()
		if let expectedRevision, expectedRevision != revision {
			throw MutationError.staleSnapshot(
				expected: expectedRevision,
				actual: revision
			)
		}
		var updated = hosts
		try transform(&updated)
		guard updated != hosts else { return currentSnapshot }
		try HostPersistence.save(updated, to: hostsURL)
		return commit(updated)
	}

	func delete(
		id: UUID,
		enqueueRemoteDeletion: Bool
	) throws -> Snapshot {
		try ensureLoaded()
		guard let host = hosts.first(where: { $0.id == id }) else {
			return currentSnapshot
		}

		let serverID = enqueueRemoteDeletion ? host.serverId : nil
		var updated = hosts
		updated.removeAll { $0.id == id }
		if serverID != nil {
			ensureOutbox()
		}
		let inserted = try serverID.map { try outbox.insert($0) } ?? false
		do {
			try HostPersistence.save(updated, to: hostsURL)
		} catch {
			guard inserted, let serverID else { throw error }
			let persistenceError = error
			do {
				try outbox.remove(serverID)
			} catch {
				throw DeletionRollbackError(
					originalError: persistenceError,
					rollbackErrors: [error]
				)
			}
			throw persistenceError
		}
		return commit(updated)
	}

	func pendingDeletionIDs() throws -> [String] {
		try ensureLoaded()
		ensureOutbox()
		return try outbox.pendingIDs()
	}

	func recordDeletion(serverID: String) throws {
		try ensureLoaded()
		ensureOutbox()
		_ = try outbox.insert(serverID)
	}

	func clearDeletion(serverID: String) throws {
		try ensureLoaded()
		ensureOutbox()
		try outbox.remove(serverID)
	}

	private var outbox: HostDeletionOutbox {
		get {
			guard let deletionOutbox else {
				preconditionFailure("SessionHostPersistence used before prepare")
			}
			return deletionOutbox
		}
		set {
			deletionOutbox = newValue
		}
	}

	private var currentSnapshot: Snapshot {
		Snapshot(hosts: hosts, revision: revision)
	}

	private func ensureLoaded() throws {
		guard !isLoaded else { return }
		hosts = try HostPersistence.load(from: hostsURL)
		isLoaded = true
	}

	private func ensureOutbox() {
		guard deletionOutbox == nil else { return }
		deletionOutbox = HostDeletionOutbox(hostsURL: hostsURL)
	}

	private func commit(_ hosts: [SSHHost]) -> Snapshot {
		self.hosts = hosts
		revision &+= 1
		return currentSnapshot
	}
}
