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
	struct AccountContext: Equatable, Sendable {
		let epoch: UInt64
	}

	public enum StoreError: Error, Equatable {
		case hostNotFound
		case accountTransitionInProgress
		case staleSnapshot
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
	private var accountEpoch: UInt64 = 0
	private var publishedRevision: UInt64 = 0
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
		let initialHosts = (try? HostPersistence.load(from: fileURL)) ?? []
		self.hosts = initialHosts
		self.persistence = MobileHostPersistence(
			hostsURL: fileURL,
			hosts: initialHosts
		)
	}

	init(
		fileURL: URL,
		credentialWriter: MobileCredentialWriter? = nil,
		managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
		credentialMaterialStore: SessionCredentialMaterialStore? = nil,
		persistence: MobileHostPersistence
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
		self.persistence = persistence
	}

	public func add(_ host: SSHHost) async throws {
		let epoch = accountEpoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			$0.append(host)
		}
		publish(snapshot, expectedEpoch: epoch)
		localMutationsSubject.send()
	}

	public func update(_ host: SSHHost) async throws {
		let epoch = accountEpoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			guard let index = $0.firstIndex(where: { $0.id == host.id }) else {
				throw StoreError.hostNotFound
			}
			$0[index] = host
		}
		publish(snapshot, expectedEpoch: epoch)
		localMutationsSubject.send()
	}

	/// Insert or replace by id and persist. Used by the shell's add/edit
	/// save callbacks, which can't know whether the form was add or edit.
	public func upsert(_ host: SSHHost) async throws {
		try await upsert(host, accountContext: currentAccountContext)
	}

	func upsert(
		_ host: SSHHost,
		accountContext: AccountContext
	) async throws {
		try requireCurrent(accountContext)
		let epoch = accountContext.epoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			if let index = $0.firstIndex(where: { $0.id == host.id }) {
				$0[index] = host
			} else {
				$0.append(host)
			}
		}
		publish(snapshot, expectedEpoch: epoch)
		localMutationsSubject.send()
	}

	public func delete(id: UUID) async throws {
		try await delete(
			id: id,
			enqueueRemoteDeletion: true,
			accountContext: currentAccountContext
		)
	}

	/// Replace the whole list and persist. The mobile shell mutates hosts
	/// through a plain `Binding<[SSHHost]>` (append/remove/replace), so a
	/// single persisting setter is the seam that keeps every UI edit on
	/// disk without threading store calls through every view.
	public func replaceAll(_ newHosts: [SSHHost]) async {
		let epoch = accountEpoch
		let revision = publishedRevision
		do {
			let snapshot = try await persistence.replaceAll(
				newHosts,
				expectedEpoch: epoch,
				expectedRevision: revision
			)
			publish(snapshot, expectedEpoch: epoch)
		} catch {
			lastPersistenceFailure = PersistenceFailure(underlyingError: error)
			return
		}
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

	private func publish(
		_ snapshot: MobileHostPersistence.Snapshot,
		expectedEpoch: UInt64
	) {
		guard accountEpoch == expectedEpoch,
			snapshot.revision >= publishedRevision else { return }
		hosts = snapshot.hosts
		publishedRevision = snapshot.revision
	}

	var currentAccountContext: AccountContext {
		AccountContext(epoch: accountEpoch)
	}

	func isCurrent(_ accountContext: AccountContext) -> Bool {
		accountContext.epoch == accountEpoch
	}

	private func requireCurrent(_ accountContext: AccountContext) throws {
		guard isCurrent(accountContext) else {
			throw StoreError.accountTransitionInProgress
		}
	}

	private func delete(
		id: UUID,
		enqueueRemoteDeletion: Bool,
		accountContext: AccountContext
	) async throws {
		try requireCurrent(accountContext)
		if let credentialWriter {
			try await credentialWriter.commitDeletion(
				hostID: id,
				transactionIsCurrent: { self.isCurrent(accountContext) }
			) {
				try await self.persistDeletion(
					id: id,
					enqueueRemoteDeletion: enqueueRemoteDeletion,
					accountContext: accountContext
				)
			}
		} else {
			try await persistDeletion(
				id: id,
				enqueueRemoteDeletion: enqueueRemoteDeletion,
				accountContext: accountContext
			)
		}
	}

	private func persistDeletion(
		id: UUID,
		enqueueRemoteDeletion: Bool,
		accountContext: AccountContext
	) async throws {
		try requireCurrent(accountContext)
		let epoch = accountContext.epoch
		let snapshot = try await persistence.delete(
			id: id,
			enqueueRemoteDeletion: enqueueRemoteDeletion,
			expectedEpoch: epoch
		)
		publish(snapshot, expectedEpoch: epoch)
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
		let epoch = accountEpoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			guard let index = $0.firstIndex(where: {
				$0.id == commit.hostId
			}) else { return }
			switch commit.source {
			case .unchanged:
				break
			case .password:
				$0[index].credential = .password
			case let .keyFile(path, hasPassphrase):
				$0[index].credential = .keyFile(
					keyPath: path,
					hasPassphrase: hasPassphrase
				)
			}
			$0[index].credentialMaterialDirty = false
		}
		publish(snapshot, expectedEpoch: epoch)
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
		accountEpoch &+= 1
		let epoch = accountEpoch
		let hostIDs = try await persistence.beginAccountReset(epoch: epoch)
		do {
			try await credentialMaterialStore
				.resetAllCredentialMaterialForAccountChange(hostIDs: hostIDs)
			let snapshot = try await persistence.completeAccountReset(epoch: epoch)
			publish(snapshot, expectedEpoch: epoch)
		} catch {
			await persistence.abortAccountReset(epoch: epoch)
			throw error
		}
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
		let epoch = accountEpoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			guard let index = $0.firstIndex(where: { $0.id == host.id }) else {
				throw StoreError.hostNotFound
			}
			var metadata = host
			metadata.credential = $0[index].credential
			metadata.credentialMaterialDirty = $0[index].credentialMaterialDirty
			metadata.updatedAt = Date()
			$0[index] = metadata
		}
		publish(snapshot, expectedEpoch: epoch)
		localMutationsSubject.send()
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await delete(
			id: id,
			enqueueRemoteDeletion: true,
			accountContext: currentAccountContext
		)
	}

	public func pendingRemoteDeletionIDs() async throws -> [String] {
		try await persistence.pendingDeletionIDs(expectedEpoch: accountEpoch)
	}

	public func recordPendingRemoteDeletion(serverID: String) async throws {
		try await persistence.recordDeletion(
			serverID: serverID,
			expectedEpoch: accountEpoch
		)
	}

	public func clearPendingRemoteDeletion(serverID: String) async throws {
		try await persistence.clearDeletion(
			serverID: serverID,
			expectedEpoch: accountEpoch
		)
	}

	public func createHostFromRemote(_ remote: RemoteHost) async throws -> UUID {
		let epoch = accountEpoch
		let result = try await persistence.createFromRemote(
			remote,
			expectedEpoch: epoch
		)
		publish(result.snapshot, expectedEpoch: epoch)
		return result.localID
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) async throws {
		let epoch = accountEpoch
		let snapshot = try await persistence.updateFromRemote(
			localID: localID,
			remote: remote,
			expectedEpoch: epoch
		)
		publish(snapshot, expectedEpoch: epoch)
	}

	public func assignServerID(_ serverID: String, to localID: UUID) async throws {
		let epoch = accountEpoch
		let snapshot = try await persistence.assignServerID(
			serverID,
			to: localID,
			expectedEpoch: epoch
		)
		publish(snapshot, expectedEpoch: epoch)
	}

	public func markCredentialMaterialSynced(for localID: UUID) async throws {
		let epoch = accountEpoch
		let snapshot = try await persistence.mutate(expectedEpoch: epoch) {
			guard let index = $0.firstIndex(where: { $0.id == localID }) else {
				throw StoreError.hostNotFound
			}
			$0[index].credentialMaterialDirty = false
		}
		publish(snapshot, expectedEpoch: epoch)
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await delete(
			id: localID,
			enqueueRemoteDeletion: false,
			accountContext: currentAccountContext
		)
	}

	public func hasIdentityBoundState() async -> Bool {
		await persistence.hasIdentityBoundState()
	}
}

actor MobileHostPersistence {
	struct Snapshot: Sendable {
		let hosts: [SSHHost]
		let revision: UInt64
	}

	private let hostsURL: URL
	private var deletionOutbox: HostDeletionOutbox
	private var hosts: [SSHHost]
	private var revision: UInt64 = 0
	private var accountEpoch: UInt64 = 0
	private var resettingAccountEpoch: UInt64?
	private let beforeMutation: @Sendable () async -> Void

	init(
		hostsURL: URL,
		hosts: [SSHHost],
		beforeMutation: @escaping @Sendable () async -> Void = {}
	) {
		self.hostsURL = hostsURL
		self.hosts = hosts
		self.deletionOutbox = HostDeletionOutbox(hostsURL: hostsURL)
		self.beforeMutation = beforeMutation
	}

	func mutate(
		expectedEpoch: UInt64,
		_ transform: @Sendable (inout [SSHHost]) throws -> Void
	) async throws -> Snapshot {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		var updated = hosts
		try transform(&updated)
		try save(updated)
		return commit(updated)
	}

	func replaceAll(
		_ newHosts: [SSHHost],
		expectedEpoch: UInt64,
		expectedRevision: UInt64
	) async throws -> Snapshot {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		guard revision == expectedRevision else {
			throw MobileHostStore.StoreError.staleSnapshot
		}
		try save(newHosts)
		return commit(newHosts)
	}

	func delete(
		id: UUID,
		enqueueRemoteDeletion: Bool,
		expectedEpoch: UInt64
	) async throws -> Snapshot {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		guard let host = hosts.first(where: { $0.id == id }) else {
			return currentSnapshot
		}
		let serverID = enqueueRemoteDeletion ? host.serverId : nil
		var updated = hosts
		updated.removeAll { $0.id == id }
		try commitDeletion(hosts: updated, serverID: serverID)
		return commit(updated)
	}

	func createFromRemote(
		_ remote: RemoteHost,
		expectedEpoch: UInt64
	) async throws -> (snapshot: Snapshot, localID: UUID) {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		let result = HostRepositoryProjection.inserting(remote, into: hosts)
		try save(result.hosts)
		return (commit(result.hosts), result.localID)
	}

	func updateFromRemote(
		localID: UUID,
		remote: RemoteHost,
		expectedEpoch: UInt64
	) async throws -> Snapshot {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		guard let updated = HostRepositoryProjection.applying(
			remote,
			to: localID,
			in: hosts
		) else {
			throw MobileHostStore.StoreError.hostNotFound
		}
		try save(updated)
		return commit(updated)
	}

	func assignServerID(
		_ serverID: String,
		to localID: UUID,
		expectedEpoch: UInt64
	) async throws -> Snapshot {
		await beforeMutation()
		try requireWritable(epoch: expectedEpoch)
		guard let updated = HostRepositoryProjection.assigning(
			serverID: serverID,
			to: localID,
			in: hosts
		) else {
			throw MobileHostStore.StoreError.hostNotFound
		}
		try save(updated)
		return commit(updated)
	}

	func beginAccountReset(epoch: UInt64) throws -> [UUID] {
		guard epoch == accountEpoch &+ 1,
			resettingAccountEpoch == nil else {
			throw MobileHostStore.StoreError.accountTransitionInProgress
		}
		accountEpoch = epoch
		resettingAccountEpoch = epoch
		return hosts.map(\.id)
	}

	func completeAccountReset(epoch: UInt64) throws -> Snapshot {
		guard resettingAccountEpoch == epoch else {
			throw MobileHostStore.StoreError.accountTransitionInProgress
		}
		try save([])
		for serverID in try deletionOutbox.pendingIDs() {
			try deletionOutbox.remove(serverID)
		}
		resettingAccountEpoch = nil
		return commit([])
	}

	func abortAccountReset(epoch: UInt64) {
		guard resettingAccountEpoch == epoch else { return }
		resettingAccountEpoch = nil
	}

	func pendingDeletionIDs(expectedEpoch: UInt64) throws -> [String] {
		try requireWritable(epoch: expectedEpoch)
		return try deletionOutbox.pendingIDs()
	}

	func recordDeletion(serverID: String, expectedEpoch: UInt64) throws {
		try requireWritable(epoch: expectedEpoch)
		_ = try deletionOutbox.insert(serverID)
	}

	func clearDeletion(serverID: String, expectedEpoch: UInt64) throws {
		try requireWritable(epoch: expectedEpoch)
		try deletionOutbox.remove(serverID)
	}

	func hasIdentityBoundState() -> Bool {
		if !hosts.isEmpty { return true }
		return ((try? deletionOutbox.pendingIDs()) ?? []).isEmpty == false
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

	private var currentSnapshot: Snapshot {
		Snapshot(hosts: hosts, revision: revision)
	}

	private func requireWritable(epoch: UInt64) throws {
		guard epoch == accountEpoch, resettingAccountEpoch == nil else {
			throw MobileHostStore.StoreError.accountTransitionInProgress
		}
	}

	private func save(_ hosts: [SSHHost]) throws {
		try HostPersistence.save(hosts, to: hostsURL)
	}

	private func commit(_ hosts: [SSHHost]) -> Snapshot {
		self.hosts = hosts
		revision &+= 1
		return currentSnapshot
	}
}
