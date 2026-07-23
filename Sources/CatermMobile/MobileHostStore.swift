import Combine
import CredentialIdentityStore
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

	public enum HostRepositoryLoadState: Equatable, Sendable {
		case loading
		case ready
		case failed(String)
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
	private let credentialIdentityStore: CredentialIdentityStore?
	public let credentialMaterialStore: SessionCredentialMaterialStore
	public let managedKeyStore: ManagedKeyStore
	private let localMutationsSubject = PassthroughSubject<Void, Never>()
	private let persistence: MobileHostPersistence
	private var accountEpoch: UInt64 = 0
	private var accountTransitionInProgress = false
	private var accountResetAwaitingAcknowledgement = false
	private var exclusiveAccountOperationInProgress = false
	private var exclusiveAccountOperationPending = false
	private var activeAccountOperations = 0
	private var pendingCredentialCleanupHostIDs: Set<UUID> = []
	private var accountOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
	private var publishedRevision: UInt64 = 0
	@Published public private(set) var lastPersistenceFailure: PersistenceFailure?
	@Published public private(set) var hostRepositoryLoadState:
		HostRepositoryLoadState = .loading

	public init(
		fileURL: URL,
		credentialWriter: MobileCredentialWriter? = nil,
		managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
		credentialMaterialStore: SessionCredentialMaterialStore? = nil,
		credentialIdentityStore: CredentialIdentityStore? = nil
	) {
		self.credentialWriter = credentialWriter
		self.credentialIdentityStore = credentialIdentityStore
		self.managedKeyStore = managedKeyStore
		self.credentialMaterialStore = credentialMaterialStore
			?? SessionCredentialMaterialStore(
				keychainService: SSHCredentialContract.keychainService,
				keychainAccessGroup: nil,
				managedKeyStore: managedKeyStore
			)
		self.hosts = []
		self.persistence = MobileHostPersistence(hostsURL: fileURL)
		Task { [weak self] in
			await self?.prepareOnLaunch()
		}
	}

	init(
		fileURL: URL,
		credentialWriter: MobileCredentialWriter? = nil,
		managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
		credentialMaterialStore: SessionCredentialMaterialStore? = nil,
		credentialIdentityStore: CredentialIdentityStore? = nil,
		persistence: MobileHostPersistence
	) {
		self.credentialWriter = credentialWriter
		self.credentialIdentityStore = credentialIdentityStore
		self.managedKeyStore = managedKeyStore
		self.credentialMaterialStore = credentialMaterialStore
			?? SessionCredentialMaterialStore(
				keychainService: SSHCredentialContract.keychainService,
				keychainAccessGroup: nil,
				managedKeyStore: managedKeyStore
			)
		self.hosts = []
		self.persistence = persistence
		Task { [weak self] in
			await self?.prepareOnLaunch()
		}
	}

	public func prepare() async throws {
		do {
			let epoch = accountEpoch
			let snapshot = try await persistence.prepare()
			publish(snapshot, expectedEpoch: epoch)
			hostRepositoryLoadState = .ready
		} catch {
			hostRepositoryLoadState = .failed(error.localizedDescription)
			throw error
		}
	}

	private func prepareOnLaunch() async {
		do {
			try await prepare()
		} catch {
			return
		}
	}

	public func retryHostRepositoryLoad() async {
		hostRepositoryLoadState = .loading
		await prepareOnLaunch()
	}

	public func add(_ host: SSHHost) async throws {
		try await withIdentityTransaction {
			try self.validateCredentialIdentityAssignments(in: [host])
			try await self.withAccountOperation { accountContext in
				let snapshot = try await self.persistence.mutate(
					expectedEpoch: accountContext.epoch
				) {
					$0.append(host)
				}
				self.publish(snapshot, expectedEpoch: accountContext.epoch)
				self.localMutationsSubject.send()
			}
		}
	}

	public func update(_ host: SSHHost) async throws {
		try await withIdentityTransaction {
			try self.validateCredentialIdentityAssignments(in: [host])
			try await self.withAccountOperation { accountContext in
				let snapshot = try await self.persistence.mutate(
					expectedEpoch: accountContext.epoch
				) {
					guard let index = $0.firstIndex(where: {
						$0.id == host.id
					}) else {
						throw StoreError.hostNotFound
					}
					$0[index] = host
				}
				self.publish(snapshot, expectedEpoch: accountContext.epoch)
				self.localMutationsSubject.send()
			}
		}
	}

	/// Insert or replace by id and persist. Used by the shell's add/edit
	/// save callbacks, which can't know whether the form was add or edit.
	public func upsert(_ host: SSHHost) async throws {
		try await withIdentityTransaction {
			try self.validateCredentialIdentityAssignments(in: [host])
			try await self.withAccountOperation { accountContext in
				try await self.upsert(host, accountContext: accountContext)
			}
		}
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
		try await withAccountOperation { accountContext in
			try await delete(
				id: id,
				enqueueRemoteDeletion: true,
				accountContext: accountContext
			)
		}
	}

	/// Replace the whole list and persist. The mobile shell mutates hosts
	/// through a plain `Binding<[SSHHost]>` (append/remove/replace), so a
	/// single persisting setter is the seam that keeps every UI edit on
	/// disk without threading store calls through every view.
	public func replaceAll(_ newHosts: [SSHHost]) async {
		do {
			try await withIdentityTransaction {
				try self.validateCredentialIdentityAssignments(
					in: newHosts
				)
				try await self.withAccountOperation { accountContext in
					try await self.replaceAll(
						newHosts,
						accountContext: accountContext
					)
				}
			}
		} catch {
			lastPersistenceFailure = PersistenceFailure(underlyingError: error)
			return
		}
	}

	func replaceAll(
		_ newHosts: [SSHHost],
		accountContext: AccountContext
	) async throws {
		try requireCurrent(accountContext)
		let revision = publishedRevision
		let snapshot = try await persistence.replaceAll(
			newHosts,
			expectedEpoch: accountContext.epoch,
			expectedRevision: revision
		)
		try requireCurrent(accountContext)
		publish(snapshot, expectedEpoch: accountContext.epoch)
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
		accountContext.epoch == accountEpoch && !accountTransitionInProgress
	}

	func beginAccountOperation() throws -> AccountContext {
		guard !accountTransitionInProgress,
			!exclusiveAccountOperationInProgress,
			!exclusiveAccountOperationPending else {
			throw StoreError.accountTransitionInProgress
		}
		activeAccountOperations += 1
		return currentAccountContext
	}

	func beginExclusiveAccountOperation() async throws -> AccountContext {
		guard !accountTransitionInProgress,
			!exclusiveAccountOperationInProgress,
			!exclusiveAccountOperationPending else {
			throw StoreError.accountTransitionInProgress
		}
		exclusiveAccountOperationPending = true
		if activeAccountOperations > 0 {
			await waitForAccountOperationsToDrain()
		}
		guard !accountTransitionInProgress,
			!exclusiveAccountOperationInProgress else {
			exclusiveAccountOperationPending = false
			throw StoreError.accountTransitionInProgress
		}
		exclusiveAccountOperationPending = false
		exclusiveAccountOperationInProgress = true
		activeAccountOperations = 1
		return currentAccountContext
	}

	func endAccountOperation() {
		precondition(activeAccountOperations > 0)
		activeAccountOperations -= 1
		if activeAccountOperations == 0 {
			exclusiveAccountOperationInProgress = false
		}
		guard activeAccountOperations == 0 else { return }
		let waiters = accountOperationDrainWaiters
		accountOperationDrainWaiters.removeAll()
		for waiter in waiters { waiter.resume() }
	}

	private func withAccountOperation<T>(
		_ operation: (AccountContext) async throws -> T
	) async throws -> T {
		let accountContext = try beginAccountOperation()
		defer { endAccountOperation() }
		return try await operation(accountContext)
	}

	private func withIdentityTransaction<T>(
		_ operation: @MainActor () async throws -> T
	) async throws -> T {
		guard let credentialIdentityStore else {
			return try await operation()
		}
		return try await credentialIdentityStore.withTransaction(operation)
	}

	func withCredentialIdentityTransaction<T>(
		for host: SSHHost,
		_ operation: @MainActor () async throws -> T
	) async throws -> T {
		try await withIdentityTransaction {
			try self.validateCredentialIdentityAssignments(in: [host])
			return try await operation()
		}
	}

	private func validateCredentialIdentityAssignments(
		in candidateHosts: [SSHHost]
	) throws {
		guard let credentialIdentityStore else { return }
		for identityID in Set(candidateHosts.compactMap {
			$0.credentialIdentity?.identityID
		}) {
			try credentialIdentityStore.validateAssignment(
				identityID: identityID
			)
		}
	}

	var isAccountTransitionInProgress: Bool { accountTransitionInProgress }

	private func requireCurrent(_ accountContext: AccountContext) throws {
		guard isCurrent(accountContext) else {
			throw StoreError.accountTransitionInProgress
		}
	}

	func registerCredentialCleanup(
		hostIDs: Set<UUID>,
		accountContext: AccountContext
	) throws {
		try requireCurrent(accountContext)
		pendingCredentialCleanupHostIDs.formUnion(hostIDs)
	}

	func unregisterCredentialCleanup(
		hostIDs: Set<UUID>,
		accountContext: AccountContext
	) throws {
		try requireCurrent(accountContext)
		pendingCredentialCleanupHostIDs.subtract(hostIDs)
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
		try await withAccountOperation { accountContext in
			let snapshot = try await persistence.mutate(
				expectedEpoch: accountContext.epoch
			) {
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
			publish(snapshot, expectedEpoch: accountContext.epoch)
		}
	}

	public func resetCredentialMaterialForAccountChange() async throws {
		let hostIDs = Set(hosts.map(\.id))
			.union(pendingCredentialCleanupHostIDs)
		try await credentialMaterialStore
			.resetAllCredentialMaterialForAccountChange(
				hostIDs: Array(hostIDs)
			)
	}

	/// Clears identity-bound local Host state only after credential material is
	/// gone. The caller keeps synchronization suspended until this succeeds.
	public func resetForAccountChange() async throws {
		if accountTransitionInProgress && accountResetAwaitingAcknowledgement {
			return
		}
		guard !accountTransitionInProgress else {
			throw StoreError.accountTransitionInProgress
		}
		accountEpoch &+= 1
		accountTransitionInProgress = true
		let epoch = accountEpoch
		await waitForAccountOperationsToDrain()
		do {
			let persistedHostIDs = try await persistence.beginAccountReset(epoch: epoch)
			let hostIDs = Set(persistedHostIDs)
				.union(pendingCredentialCleanupHostIDs)
			try await credentialMaterialStore
				.resetAllCredentialMaterialForAccountChange(hostIDs: Array(hostIDs))
			let snapshot = try await persistence.completeAccountReset(epoch: epoch)
			publish(snapshot, expectedEpoch: epoch)
			pendingCredentialCleanupHostIDs.removeAll()
			accountResetAwaitingAcknowledgement = true
		} catch {
			await persistence.abortAccountReset(epoch: epoch)
			accountResetAwaitingAcknowledgement = false
			accountTransitionInProgress = false
			throw error
		}
	}

	func finishAccountTransition() throws {
		guard accountTransitionInProgress,
			accountResetAwaitingAcknowledgement else {
			throw StoreError.accountTransitionInProgress
		}
		accountResetAwaitingAcknowledgement = false
		accountTransitionInProgress = false
	}

	private func waitForAccountOperationsToDrain() async {
		guard activeAccountOperations > 0 else { return }
		await withCheckedContinuation { continuation in
			accountOperationDrainWaiters.append(continuation)
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
		try await withIdentityTransaction {
			try self.validateCredentialIdentityAssignments(in: [host])
			try await self.withAccountOperation { accountContext in
				let snapshot = try await self.persistence.mutate(
					expectedEpoch: accountContext.epoch
				) {
					guard let index = $0.firstIndex(where: {
						$0.id == host.id
					}) else {
						throw StoreError.hostNotFound
					}
					var metadata = host
					metadata.credential = $0[index].credential
					metadata.credentialMaterialDirty =
						$0[index].credentialMaterialDirty
					metadata.updatedAt = Date()
					$0[index] = metadata
				}
				self.publish(snapshot, expectedEpoch: accountContext.epoch)
				self.localMutationsSubject.send()
			}
		}
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await delete(id: id)
	}

	public func pendingRemoteDeletionIDs() async throws -> [String] {
		try await persistence.pendingDeletionIDs(expectedEpoch: accountEpoch)
	}

	public func recordPendingRemoteDeletion(serverID: String) async throws {
		try await withAccountOperation { accountContext in
			try await persistence.recordDeletion(
				serverID: serverID,
				expectedEpoch: accountContext.epoch
			)
		}
	}

	public func clearPendingRemoteDeletion(serverID: String) async throws {
		try await withAccountOperation { accountContext in
			try await persistence.clearDeletion(
				serverID: serverID,
				expectedEpoch: accountContext.epoch
			)
		}
	}

	public func createHostFromRemote(_ remote: RemoteHost) async throws -> UUID {
		try await withIdentityTransaction {
			let candidate = HostRepositoryProjection.inserting(
				remote,
				into: self.hosts
			)
			try self.validateCredentialIdentityAssignments(
				in: candidate.hosts
			)
			return try await self.withAccountOperation { accountContext in
				let result = try await self.persistence.createFromRemote(
					remote,
					expectedEpoch: accountContext.epoch
				)
				self.publish(
					result.snapshot,
					expectedEpoch: accountContext.epoch
				)
				return result.localID
			}
		}
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) async throws {
		try await withIdentityTransaction {
			guard let candidate = HostRepositoryProjection.applying(
				remote,
				to: localID,
				in: self.hosts
			) else {
				throw StoreError.hostNotFound
			}
			try self.validateCredentialIdentityAssignments(in: candidate)
			try await self.withAccountOperation { accountContext in
				let snapshot = try await self.persistence.updateFromRemote(
					localID: localID,
					remote: remote,
					expectedEpoch: accountContext.epoch
				)
				self.publish(
					snapshot,
					expectedEpoch: accountContext.epoch
				)
			}
		}
	}

	public func assignServerID(_ serverID: String, to localID: UUID) async throws {
		try await withAccountOperation { accountContext in
			let snapshot = try await persistence.assignServerID(
				serverID,
				to: localID,
				expectedEpoch: accountContext.epoch
			)
			publish(snapshot, expectedEpoch: accountContext.epoch)
		}
	}

	public func markCredentialMaterialSynced(for localID: UUID) async throws {
		try await withAccountOperation { accountContext in
			let snapshot = try await persistence.mutate(
				expectedEpoch: accountContext.epoch
			) {
				guard let index = $0.firstIndex(where: { $0.id == localID }) else {
					throw StoreError.hostNotFound
				}
				$0[index].credentialMaterialDirty = false
			}
			publish(snapshot, expectedEpoch: accountContext.epoch)
		}
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await withAccountOperation { accountContext in
			try await delete(
				id: localID,
				enqueueRemoteDeletion: false,
				accountContext: accountContext
			)
		}
	}

	public func hasIdentityBoundState() async -> Bool {
		if !pendingCredentialCleanupHostIDs.isEmpty { return true }
		return await persistence.hasIdentityBoundState()
	}
}

actor MobileHostPersistence {
	struct Snapshot: Sendable {
		let hosts: [SSHHost]
		let revision: UInt64
	}

	private let hostsURL: URL
	private var deletionOutbox: HostDeletionOutbox?
	private var hosts: [SSHHost] = []
	private var revision: UInt64 = 0
	private var accountEpoch: UInt64 = 0
	private var resettingAccountEpoch: UInt64?
	private var isLoaded = false
	private let beforeMutation: @Sendable () async -> Void

	init(
		hostsURL: URL,
		beforeMutation: @escaping @Sendable () async -> Void = {}
	) {
		self.hostsURL = hostsURL
		self.beforeMutation = beforeMutation
	}

	func prepare() throws -> Snapshot {
		try ensureLoaded()
		return currentSnapshot
	}

	func mutate(
		expectedEpoch: UInt64,
		_ transform: @Sendable (inout [SSHHost]) throws -> Void
	) async throws -> Snapshot {
		await beforeMutation()
		try ensureLoaded()
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
		try ensureLoaded()
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
		try ensureLoaded()
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
		try ensureLoaded()
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
		try ensureLoaded()
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
		try ensureLoaded()
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
		try ensureLoaded()
		guard epoch == accountEpoch &+ 1,
			resettingAccountEpoch == nil else {
			throw MobileHostStore.StoreError.accountTransitionInProgress
		}
		accountEpoch = epoch
		resettingAccountEpoch = epoch
		return hosts.map(\.id)
	}

	func completeAccountReset(epoch: UInt64) throws -> Snapshot {
		try ensureLoaded()
		guard resettingAccountEpoch == epoch else {
			throw MobileHostStore.StoreError.accountTransitionInProgress
		}
		try save([])
		for serverID in try outbox.pendingIDs() {
			try outbox.remove(serverID)
		}
		resettingAccountEpoch = nil
		return commit([])
	}

	func abortAccountReset(epoch: UInt64) {
		guard resettingAccountEpoch == epoch else { return }
		resettingAccountEpoch = nil
	}

	func pendingDeletionIDs(expectedEpoch: UInt64) throws -> [String] {
		try ensureLoaded()
		try requireWritable(epoch: expectedEpoch)
		return try outbox.pendingIDs()
	}

	func recordDeletion(serverID: String, expectedEpoch: UInt64) throws {
		try ensureLoaded()
		try requireWritable(epoch: expectedEpoch)
		_ = try outbox.insert(serverID)
	}

	func clearDeletion(serverID: String, expectedEpoch: UInt64) throws {
		try ensureLoaded()
		try requireWritable(epoch: expectedEpoch)
		try outbox.remove(serverID)
	}

	func hasIdentityBoundState() -> Bool {
		do {
			try ensureLoaded()
		} catch {
			return true
		}
		if !hosts.isEmpty { return true }
		do {
			return try !outbox.pendingIDs().isEmpty
		} catch {
			return true
		}
	}

	func commitDeletion(hosts: [SSHHost], serverID: String?) throws {
		let inserted = try serverID.map { try outbox.insert($0) } ?? false
		do {
			try HostPersistence.save(hosts, to: hostsURL)
		} catch {
			guard inserted, let serverID else { throw error }
			let originalError = error
			do {
				try outbox.remove(serverID)
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

	private var outbox: HostDeletionOutbox {
		get {
			guard let deletionOutbox else {
				preconditionFailure("MobileHostPersistence used before prepare")
			}
			return deletionOutbox
		}
		set {
			deletionOutbox = newValue
		}
	}

	private func ensureLoaded() throws {
		guard !isLoaded else { return }
		hosts = try HostPersistence.load(from: hostsURL)
		deletionOutbox = HostDeletionOutbox(hostsURL: hostsURL)
		isLoaded = true
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
