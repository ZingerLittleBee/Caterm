import Combine
import CredentialSync
import Foundation
import HostRepositoryCore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import SSHCredentialContract
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

	public struct DeletionRollbackError: Error {
		public let originalError: any Error
		public let rollbackErrors: [any Error]
	}

	@Published public private(set) var hosts: [SSHHost]

	public struct PersistenceFailure: Error, Identifiable {
		public let id = UUID()
		public let underlyingError: any Error
	}

	private let credentialWriter: MobileCredentialWriter?
	public let credentialMaterialStore: SessionCredentialMaterialStore
	public let managedKeyStore: ManagedKeyStore
	private let localMutationsSubject = PassthroughSubject<Void, Never>()
	private let persistence: MobileHostPersistence
	@Published public private(set) var lastPersistenceFailure: PersistenceFailure?

	public init(
		fileURL: URL,
		credentialWriter: MobileCredentialWriter? = nil,
		managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
		credentialMaterialStore: SessionCredentialMaterialStore? = nil
	) {
		self.credentialWriter = credentialWriter
		self.managedKeyStore = managedKeyStore
		self.credentialMaterialStore = credentialMaterialStore
			?? SessionCredentialMaterialStore(
				keychainService: SSHCredentialContract.keychainService,
				keychainAccessGroup: nil,
				managedKeyStore: managedKeyStore
			)
		self.hosts = (try? HostPersistence.load(from: fileURL)) ?? []
		self.persistence = MobileHostPersistence(hostsURL: fileURL)
	}

	public func add(_ host: SSHHost) async throws {
		var updated = hosts
		updated.append(host)
		try await persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	public func update(_ host: SSHHost) async throws {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		updated[index] = host
		try await persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	/// Insert or replace by id and persist. Used by the shell's add/edit
	/// save callbacks, which can't know whether the form was add or edit.
	public func upsert(_ host: SSHHost) async throws {
		var updated = hosts
		if let index = updated.firstIndex(where: { $0.id == host.id }) {
			updated[index] = host
		} else {
			updated.append(host)
		}
		try await persist(updated)
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
	public func replaceAll(_ newHosts: [SSHHost]) async {
		do {
			try await persist(newHosts)
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
			set: { newHosts in
				Task { @MainActor in await self.replaceAll(newHosts) }
			}
		)
	}

	private func persist(_ hosts: [SSHHost]) async throws {
		try await persistence.save(hosts)
	}

	private func delete(id: UUID, enqueueRemoteDeletion: Bool) async throws {
		if let credentialWriter {
			try await credentialWriter.commitDeletion(hostID: id) {
				try await self.persistDeletion(
					id: id,
					enqueueRemoteDeletion: enqueueRemoteDeletion
				)
			}
		} else {
			try await persistDeletion(
				id: id,
				enqueueRemoteDeletion: enqueueRemoteDeletion
			)
		}
	}

	private func persistDeletion(
		id: UUID,
		enqueueRemoteDeletion: Bool
	) async throws {
		guard let host = hosts.first(where: { $0.id == id }) else { return }
		let serverID = enqueueRemoteDeletion ? host.serverId : nil
		var updated = hosts
		updated.removeAll { $0.id == id }
		try await persistence.commitDeletion(
			hosts: updated,
			serverID: serverID
		)
		hosts = updated
		if enqueueRemoteDeletion {
			localMutationsSubject.send()
		}
	}

}

extension MobileHostStore: HostCredentialRepository {
	public func managedKeyPath(for hostID: UUID) -> String {
		managedKeyStore.path(hostId: hostID).path
	}

	public func applyRemoteCredentialSource(
		_ commit: RemoteCredentialMaterialCommit
	) async throws {
		guard let index = hosts.firstIndex(where: {
			$0.id == commit.hostId
		}) else { return }
		var updated = hosts
		switch commit.source {
		case .unchanged:
			break
		case .password:
			updated[index].credential = .password
		case let .keyFile(path, hasPassphrase):
			updated[index].credential = .keyFile(
				keyPath: path,
				hasPassphrase: hasPassphrase
			)
		}
		updated[index].credentialMaterialDirty = false
		try await persist(updated)
		hosts = updated
	}

	public func resetCredentialMaterialForAccountChange() async throws {
		try await credentialMaterialStore
			.resetAllCredentialMaterialForAccountChange(
				hostIDs: hosts.map(\.id)
			)
	}

	/// Clears identity-bound local Host state only after credential material is
	/// gone. The caller keeps synchronization suspended until this succeeds.
	public func resetForAccountChange() async throws {
		try await resetCredentialMaterialForAccountChange()
		try await persistence.reset()
		hosts = []
	}
}

extension MobileHostStore {
	public var hostSnapshot: [SSHHost] { hosts }
	public var localMutations: AnyPublisher<Void, Never> {
		localMutationsSubject.eraseToAnyPublisher()
	}

	public func createLocalHost(_ host: SSHHost) async throws {
		try await add(host)
	}

	public func updateLocalHostMetadata(_ host: SSHHost) async throws {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		var metadata = host
		metadata.credential = updated[index].credential
		metadata.credentialMaterialDirty = updated[index].credentialMaterialDirty
		metadata.updatedAt = Date()
		updated[index] = metadata
		try await persist(updated)
		hosts = updated
		localMutationsSubject.send()
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await delete(id: id, enqueueRemoteDeletion: true)
	}

	public func pendingRemoteDeletionIDs() async throws -> [String] {
		try await persistence.pendingDeletionIDs()
	}

	public func recordPendingRemoteDeletion(serverID: String) async throws {
		try await persistence.recordDeletion(serverID: serverID)
	}

	public func clearPendingRemoteDeletion(serverID: String) async throws {
		try await persistence.clearDeletion(serverID: serverID)
	}

	public func createHostFromRemote(_ remote: RemoteHost) async throws -> UUID {
		let result = HostRepositoryProjection.inserting(remote, into: hosts)
		try await persist(result.hosts)
		hosts = result.hosts
		return result.localID
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) async throws {
		guard let updated = HostRepositoryProjection.applying(
			remote,
			to: localID,
			in: hosts
		) else {
			throw StoreError.hostNotFound
		}
		try await persist(updated)
		hosts = updated
	}

	public func assignServerID(_ serverID: String, to localID: UUID) async throws {
		guard let updated = HostRepositoryProjection.assigning(
			serverID: serverID,
			to: localID,
			in: hosts
		) else {
			throw StoreError.hostNotFound
		}
		try await persist(updated)
		hosts = updated
	}

	public func markCredentialMaterialSynced(for localID: UUID) async throws {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			throw StoreError.hostNotFound
		}
		guard hosts[index].credentialMaterialDirty else { return }
		var updated = hosts
		updated[index].credentialMaterialDirty = false
		try await persist(updated)
		hosts = updated
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await delete(id: localID, enqueueRemoteDeletion: false)
	}
}

private actor MobileHostPersistence {
	private let hostsURL: URL
	private var deletionOutbox: HostDeletionOutbox

	init(hostsURL: URL) {
		self.hostsURL = hostsURL
		self.deletionOutbox = HostDeletionOutbox(hostsURL: hostsURL)
	}

	func save(_ hosts: [SSHHost]) throws {
		try HostPersistence.save(hosts, to: hostsURL)
	}

	func pendingDeletionIDs() throws -> [String] {
		try deletionOutbox.pendingIDs()
	}

	func recordDeletion(serverID: String) throws {
		_ = try deletionOutbox.insert(serverID)
	}

	func clearDeletion(serverID: String) throws {
		try deletionOutbox.remove(serverID)
	}

	func commitDeletion(hosts: [SSHHost], serverID: String?) throws {
		let inserted = try serverID.map { try deletionOutbox.insert($0) } ?? false
		do {
			try HostPersistence.save(hosts, to: hostsURL)
		} catch {
			guard inserted, let serverID else { throw error }
			let originalError = error
			do {
				try deletionOutbox.remove(serverID)
			} catch {
				throw MobileHostStore.DeletionRollbackError(
					originalError: originalError,
					rollbackErrors: [error]
				)
			}
			throw originalError
		}
	}

	func reset() throws {
		try HostPersistence.save([], to: hostsURL)
		for serverID in try deletionOutbox.pendingIDs() {
			try deletionOutbox.remove(serverID)
		}
	}
}
