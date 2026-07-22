import Combine
import Foundation
import HostRepositoryCore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Mobile host store. Backs the mobile shell with the same on-disk host
/// JSON the macOS app and CloudKit sync use (`HostPersistence`), without
/// pulling in `SessionStore`'s desktop tab/terminal/SSH-config machinery.
/// This keeps AppKit isolated while staying format-compatible with desktop.
@MainActor
public final class MobileHostStore: ObservableObject {
	public enum StoreError: Error, Equatable {
		case hostNotFound
	}

	@Published public private(set) var hosts: [SSHHost]

	public struct DeletionRollbackError: Error {
		public let originalError: any Error
		public let rollbackErrors: [any Error]
	}

	public struct PersistenceFailure: Error, Identifiable {
		public let id = UUID()
		public let underlyingError: any Error
	}

	private let fileURL: URL
	private let credentialCleanup: @Sendable (UUID) async throws -> Void
	private let localMutationsSubject = PassthroughSubject<Void, Never>()
	private var deletionOutbox: HostDeletionOutbox
	@Published public private(set) var lastPersistenceFailure: PersistenceFailure?

	public init(
		fileURL: URL,
		credentialCleanup: @escaping @Sendable (UUID) async throws -> Void = { _ in }
	) {
		self.fileURL = fileURL
		self.credentialCleanup = credentialCleanup
		self.hosts = (try? HostPersistence.load(from: fileURL)) ?? []
		self.deletionOutbox = HostDeletionOutbox(hostsURL: fileURL)
	}

	public func add(_ host: SSHHost) throws {
		var updated = hosts
		updated.append(host)
		try persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	public func update(_ host: SSHHost) throws {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		updated[index] = host
		try persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	/// Insert or replace by id and persist. Used by the shell's add/edit
	/// save callbacks, which can't know whether the form was add or edit.
	public func upsert(_ host: SSHHost) throws {
		var updated = hosts
		if let index = updated.firstIndex(where: { $0.id == host.id }) {
			updated[index] = host
		} else {
			updated.append(host)
		}
		try persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	public func delete(id: UUID) async throws {
		try await delete(id: id, enqueueRemoteDeletion: true)
	}

	/// Replace the whole list and persist. The mobile shell mutates hosts
	/// through a plain `Binding<[SSHHost]>` (append/remove/replace), so a
	/// single persisting setter is the seam that keeps every UI edit on
	/// disk without threading store calls through every view.
	public func replaceAll(_ newHosts: [SSHHost]) {
		do {
			try persist(newHosts)
		} catch {
			lastPersistenceFailure = PersistenceFailure(underlyingError: error)
			return
		}
		hosts = newHosts
		localMutationsSubject.send()
	}

	public func clearPersistenceFailure() {
		lastPersistenceFailure = nil
	}

	/// `Binding` view of the host list whose setter persists. Feed this to
	/// the array-based shell so all edits round-trip to the shared file.
	public var binding: Binding<[SSHHost]> {
		Binding(
			get: { self.hosts },
			set: { self.replaceAll($0) }
		)
	}

	private func persist(_ hosts: [SSHHost]) throws {
		try HostPersistence.save(hosts, to: fileURL)
	}

	private func delete(id: UUID, enqueueRemoteDeletion: Bool) async throws {
		guard let host = hosts.first(where: { $0.id == id }) else { return }
		let serverID = enqueueRemoteDeletion ? host.serverId : nil
		let inserted = try serverID.map { try deletionOutbox.insert($0) } ?? false
		var updated = hosts
		updated.removeAll { $0.id == id }
		do {
			try persist(updated)
		} catch {
			try rollbackDeletionIntent(
				originalError: error,
				insertedServerID: inserted ? serverID : nil
			)
		}
		do {
			try await credentialCleanup(id)
		} catch {
			var rollbackErrors: [any Error] = []
			do {
				try persist(hosts)
			} catch {
				rollbackErrors.append(error)
			}
			if inserted, let serverID {
				do {
					try deletionOutbox.remove(serverID)
				} catch {
					rollbackErrors.append(error)
				}
			}
			guard rollbackErrors.isEmpty else {
				throw DeletionRollbackError(
					originalError: error,
					rollbackErrors: rollbackErrors
				)
			}
			throw error
		}
		hosts = updated
		if enqueueRemoteDeletion {
			localMutationsSubject.send()
		}
	}

	private func rollbackDeletionIntent(
		originalError: any Error,
		insertedServerID: String?
	) throws -> Never {
		guard let insertedServerID else { throw originalError }
		do {
			try deletionOutbox.remove(insertedServerID)
		} catch {
			throw DeletionRollbackError(
				originalError: originalError,
				rollbackErrors: [error]
			)
		}
		throw originalError
	}

}

extension MobileHostStore: HostRepository {
	public var hostSnapshot: [SSHHost] { hosts }
	public var localMutations: AnyPublisher<Void, Never> {
		localMutationsSubject.eraseToAnyPublisher()
	}

	public func createLocalHost(_ host: SSHHost) throws {
		try add(host)
	}

	public func updateLocalHostMetadata(_ host: SSHHost) throws {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		var metadata = host
		metadata.credential = updated[index].credential
		metadata.credentialMaterialDirty = updated[index].credentialMaterialDirty
		metadata.updatedAt = Date()
		updated[index] = metadata
		try persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await delete(id: id, enqueueRemoteDeletion: true)
	}

	public func pendingRemoteDeletionIDs() throws -> [String] {
		try deletionOutbox.pendingIDs()
	}

	public func clearPendingRemoteDeletion(serverID: String) throws {
		try deletionOutbox.remove(serverID)
	}

	public func createHostFromRemote(_ remote: RemoteHost) throws -> UUID {
		let result = HostRepositoryProjection.inserting(remote, into: hosts)
		try persist(result.hosts)
		hosts = result.hosts
		return result.localID
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) throws {
		guard let updated = HostRepositoryProjection.applying(
			remote,
			to: localID,
			in: hosts
		) else {
			throw StoreError.hostNotFound
		}
		try persist(updated)
		hosts = updated
	}

	public func assignServerID(_ serverID: String, to localID: UUID) throws {
		guard let updated = HostRepositoryProjection.assigning(
			serverID: serverID,
			to: localID,
			in: hosts
		) else {
			throw StoreError.hostNotFound
		}
		try persist(updated)
		hosts = updated
	}

	public func markCredentialMaterialSynced(for localID: UUID) throws {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			throw StoreError.hostNotFound
		}
		guard hosts[index].credentialMaterialDirty else { return }
		var updated = hosts
		updated[index].credentialMaterialDirty = false
		try persist(updated)
		hosts = updated
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await delete(id: localID, enqueueRemoteDeletion: false)
	}
}
