import Foundation
import KeychainStore
import ManagedKeyStore
import os
import SSHCommandBuilder
import SSHCredentialContract

protocol CredentialSecretStoring: Sendable {
	func get(
		account: String,
		interaction: KeychainReadInteraction
	) throws -> String
	func set(account: String, secret: String) throws
	func delete(account: String) throws
	func deleteAll(prefix: String) throws
}

extension CredentialSecretStoring {
	func get(account: String) throws -> String {
		try get(account: account, interaction: .userInitiated)
	}
}

private struct KeychainCredentialSecretStore: CredentialSecretStoring,
	@unchecked Sendable {
	let keychain: KeychainStore

	func get(
		account: String,
		interaction: KeychainReadInteraction
	) throws -> String {
		try keychain.get(account: account, interaction: interaction)
	}

	func set(account: String, secret: String) throws {
		try keychain.set(account: account, secret: secret)
	}

	func delete(account: String) throws {
		try keychain.delete(account: account)
	}

	func deleteAll(prefix: String) throws {
		try keychain.deleteAll(prefix: prefix)
	}
}

public enum SessionCredentialMaterialError: Error, Equatable {
	case privateKeyRequiresKeyFileSource
	case supersededByAccountReset
	case invalidReadBarrier
}

public struct StoredCredentialMaterialSnapshot: Sendable {
	public let generation: UInt64
	public let password: Data?
	public let passphrase: Data?
	public let managedPrivateKey: Data?
}

public struct CredentialMaterialSelection: OptionSet, Sendable {
	public let rawValue: UInt8

	public init(rawValue: UInt8) {
		self.rawValue = rawValue
	}

	public static let password = Self(rawValue: 1 << 0)
	public static let passphrase = Self(rawValue: 1 << 1)
	public static let managedPrivateKey = Self(rawValue: 1 << 2)
	public static let all: Self = [
		.password,
		.passphrase,
		.managedPrivateKey,
	]
}

public struct CredentialGenerationValidation: Sendable {
	let id: UUID
	let hostId: UUID
}

public struct CredentialSetupCheck: Sendable {
	public let requiresSetup: Bool
	let id: UUID
	let hostId: UUID
}

public struct CredentialMaterialReadBarrier: Sendable {
	let id: UUID
}

enum LocalCredentialSource: Equatable, Sendable {
	case password
	case keyFile(path: String, hasPassphrase: Bool)
	case agent
}

struct LocalCredentialMaterialCommit: Sendable {
	let source: LocalCredentialSource
	let id: UUID
	let hostId: UUID
}

public enum RemoteCredentialSource: Equatable, Sendable {
	case unchanged
	case password
	case keyFile(path: String, hasPassphrase: Bool)
}

public struct RemoteCredentialMaterialCommit: Sendable {
	public let source: RemoteCredentialSource
	let id: UUID
	let hostId: UUID
}

public enum RemoteCredentialCommitDisposition: Sendable {
	case commit
	case rollback
	case discard
}

struct CredentialMaterialDeletionCommit: Sendable {
	let id: UUID
	let hostId: UUID
}

struct CredentialMaterialMigrationCommit: Sendable {
	let managedPath: String
	let id: UUID
	let hostId: UUID
}

/// Serializes credential-material transactions per host. A transaction keeps
/// its lease until the main actor has committed or rejected the corresponding
/// host metadata, so readers never observe mixed material and source state.
public actor SessionCredentialMaterialStore {
	private struct LeaseWaiter {
		let id: UUID
		let continuation: CheckedContinuation<Void, Error>
	}

	private struct GlobalLeaseWaiter {
		let id: UUID
		let continuation: CheckedContinuation<Void, Error>
	}

	private struct RollbackState {
		let wrotePassword: Bool
		let previousPassword: Data?
		let wrotePassphrase: Bool
		let previousPassphrase: Data?
		let wrotePrivateKey: Bool
		let previousPrivateKey: Data?
	}

	private struct ActiveCommit {
		let id: UUID
		let rollback: RollbackState
		var status: Status

		enum Status {
			case provisional
			case terminating
		}
	}

	private let secrets: any CredentialSecretStoring
	nonisolated let managedKeyStore: ManagedKeyStore
	private static let log = Logger(
		subsystem: "com.caterm.app",
		category: "credential-material"
	)
	private var generations: [UUID: UInt64] = [:]
	private var globalGeneration: UInt64 = 0
	private var activeLeases: [UUID: UUID] = [:]
	private var leaseWaiters: [UUID: [LeaseWaiter]] = [:]
	private var activeGlobalLease: UUID?
	private var globalLeaseWaiters: [GlobalLeaseWaiter] = []
	private var activeCommits: [UUID: ActiveCommit] = [:]

	init(
		keychainService: String,
		keychainAccessGroup: String?,
		managedKeyStore: ManagedKeyStore
	) {
		secrets = KeychainCredentialSecretStore(
			keychain: KeychainStore(
				service: keychainService,
				accessGroup: keychainAccessGroup
			)
		)
		self.managedKeyStore = managedKeyStore
	}

	init(
		secrets: any CredentialSecretStoring,
		managedKeyStore: ManagedKeyStore
	) {
		self.secrets = secrets
		self.managedKeyStore = managedKeyStore
	}

	/// Writes local material and returns a provisional commit while retaining
	/// the host lease. The caller must finalize, roll back, or discard it.
	func applyLocal(
		_ secrets: HostSecrets,
		source: LocalCredentialSource,
		for hostId: UUID
	) async throws -> LocalCredentialMaterialCommit {
		if secrets.privateKeyBytes != nil {
			guard case .keyFile = source else {
				throw SessionCredentialMaterialError.privateKeyRequiresKeyFileSource
			}
		}

		let commitID = try await acquireLease(for: hostId)
		var rollback: RollbackState?
		do {
			try Task.checkCancellation()
			let captured = try captureRollbackState(
				for: secrets,
				hostId: hostId
			)
			rollback = captured
			let managedPath = try await writeMaterial(
				secrets,
				hostId: hostId
			)
			let resolvedSource = resolveLocalSource(
				source,
				managedPath: managedPath
			)
			activeCommits[hostId] = ActiveCommit(
				id: commitID,
				rollback: captured,
				status: .provisional
			)
			return LocalCredentialMaterialCommit(
				source: resolvedSource,
				id: commitID,
				hostId: hostId
			)
		} catch {
			let originalError = error
			if let rollback {
				do {
					try await restore(rollback, hostId: hostId)
				} catch {
					advanceGeneration(for: hostId)
					logRollbackFailure(error, hostId: hostId)
				}
			}
			releaseLease(for: hostId, id: commitID)
			throw originalError
		}
	}

	func finalizeLocalCommit(_ commit: LocalCredentialMaterialCommit) {
		guard isProvisionalCommit(id: commit.id, hostId: commit.hostId) else {
			return
		}
		advanceGeneration(for: commit.hostId)
		finishCommit(id: commit.id, hostId: commit.hostId)
	}

	func rollbackLocalCommit(
		_ commit: LocalCredentialMaterialCommit
	) async throws {
		try await rollbackCommit(id: commit.id, hostId: commit.hostId)
	}

	func discardLocalCommitForDeletedHost(
		_ commit: LocalCredentialMaterialCommit
	) async throws {
		try await discardCommit(id: commit.id, hostId: commit.hostId)
	}

	/// Relocates a legacy external private key without marking the credential
	/// dirty. The generation check prevents launch migration from overwriting a
	/// credential transaction that completed while the file was being read.
	func applyMigration(
		privateKeyBytes: Data,
		for hostId: UUID,
		expectedGeneration: UInt64
	) async throws -> CredentialMaterialMigrationCommit? {
		let commitID = try await acquireLease(for: hostId)
		guard generation(for: hostId) == expectedGeneration else {
			releaseLease(for: hostId, id: commitID)
			return nil
		}

		let material = HostSecrets(privateKeyBytes: privateKeyBytes)
		var rollback: RollbackState?
		do {
			try Task.checkCancellation()
			let captured = try captureRollbackState(
				for: material,
				hostId: hostId
			)
			rollback = captured
			let managedPath = try await managedKeyStore.write(
				hostId: hostId,
				bytes: privateKeyBytes
			).path
			try Task.checkCancellation()
			activeCommits[hostId] = ActiveCommit(
				id: commitID,
				rollback: captured,
				status: .provisional
			)
			return CredentialMaterialMigrationCommit(
				managedPath: managedPath,
				id: commitID,
				hostId: hostId
			)
		} catch {
			let originalError = error
			if let rollback {
				do {
					try await restore(rollback, hostId: hostId)
				} catch {
					advanceGeneration(for: hostId)
					logRollbackFailure(error, hostId: hostId)
				}
			}
			releaseLease(for: hostId, id: commitID)
			throw originalError
		}
	}

	func finalizeMigration(_ commit: CredentialMaterialMigrationCommit) {
		guard isProvisionalCommit(id: commit.id, hostId: commit.hostId) else {
			return
		}
		advanceGeneration(for: commit.hostId)
		finishCommit(id: commit.id, hostId: commit.hostId)
	}

	func rollbackMigration(
		_ commit: CredentialMaterialMigrationCommit
	) async throws {
		try await rollbackCommit(id: commit.id, hostId: commit.hostId)
	}

	func discardMigrationForDeletedHost(
		_ commit: CredentialMaterialMigrationCommit
	) async throws {
		try await discardCommit(id: commit.id, hostId: commit.hostId)
	}

	/// Returns a material snapshot that cannot overlap a local or remote commit.
	public func snapshot(
		for hostId: UUID
	) async throws -> StoredCredentialMaterialSnapshot {
		try await snapshot(for: hostId, selecting: .all)
	}

	/// Reads only the requested fields while preserving the host generation.
	/// Callers use this to avoid touching stale or unrelated credential stores.
	public func snapshot(
		for hostId: UUID,
		selecting selection: CredentialMaterialSelection
	) async throws -> StoredCredentialMaterialSnapshot {
		try await snapshot(
			for: hostId,
			selecting: selection,
			interaction: .userInitiated
		)
	}

	/// Reads selected fields without presenting authentication UI when the
	/// caller is performing unattended work.
	public func snapshot(
		for hostId: UUID,
		selecting selection: CredentialMaterialSelection,
		interaction: KeychainReadInteraction
	) async throws -> StoredCredentialMaterialSnapshot {
		let leaseID = try await acquireLease(for: hostId)
		defer { releaseLease(for: hostId, id: leaseID) }
		return try readSnapshot(
			for: hostId,
			selecting: selection,
			interaction: interaction
		)
	}

	/// Acquires a store-wide read boundary. The caller must release it after
	/// taking every host snapshot so account reset cannot split the batch.
	public func beginReadBarrier() async throws -> CredentialMaterialReadBarrier {
		CredentialMaterialReadBarrier(
			id: try await acquireGlobalLease(
				rejectQueuedHostTransactions: false
			)
		)
	}

	public func snapshot(
		for hostId: UUID,
		under barrier: CredentialMaterialReadBarrier
	) throws -> StoredCredentialMaterialSnapshot {
		guard activeGlobalLease == barrier.id else {
			throw SessionCredentialMaterialError.invalidReadBarrier
		}
		return try readSnapshot(
			for: hostId,
			selecting: .all,
			interaction: .userInitiated
		)
	}

	public func finishReadBarrier(_ barrier: CredentialMaterialReadBarrier) {
		releaseGlobalLease(id: barrier.id)
	}

	private func readSnapshot(
		for hostId: UUID,
		selecting selection: CredentialMaterialSelection,
		interaction: KeychainReadInteraction
	) throws -> StoredCredentialMaterialSnapshot {
		return StoredCredentialMaterialSnapshot(
			generation: generation(for: hostId),
			password: selection.contains(.password)
				? try optionalSecret(
					account: SSHCredentialContract.account(
						hostID: hostId, kind: .password
					),
					interaction: interaction
				)
				: nil,
			passphrase: selection.contains(.passphrase)
				? try optionalSecret(
					account: SSHCredentialContract.account(
						hostID: hostId, kind: .keyPassphrase
					),
					interaction: interaction
				)
				: nil,
			managedPrivateKey: selection.contains(.managedPrivateKey)
				? try managedKeyStore.read(hostId: hostId)
				: nil
		)
	}

	public func currentGeneration(for hostId: UUID) -> UInt64 {
		generation(for: hostId)
	}

	/// Reads credential availability while holding the same per-host lease used
	/// by material mutations, so callers cannot observe provisional bytes before
	/// the corresponding host source has committed on the main actor.
	public func beginCredentialSetupCheck(
		for hostId: UUID,
		source: CredentialSource,
		interaction: KeychainReadInteraction
	) async -> CredentialSetupCheck? {
		let leaseID: UUID
		do {
			leaseID = try await acquireLease(for: hostId)
		} catch {
			return nil
		}

		let requiresSetup: Bool
		do {
			switch source {
			case .agent:
				requiresSetup = false
			case .password:
				requiresSetup = try !hasSecret(
					account: SSHCredentialContract.account(
						hostID: hostId, kind: .password
					),
					interaction: interaction
				)
			case let .keyFile(keyPath, hasPassphrase):
				if !FileManager.default.fileExists(atPath: keyPath) {
					requiresSetup = true
				} else if hasPassphrase {
					requiresSetup = try !hasSecret(
						account: SSHCredentialContract.account(
							hostID: hostId, kind: .keyPassphrase
						),
						interaction: interaction
					)
				} else {
					requiresSetup = false
				}
			}
		} catch {
			releaseLease(for: hostId, id: leaseID)
			return nil
		}
		return CredentialSetupCheck(
			requiresSetup: requiresSetup,
			id: leaseID,
			hostId: hostId
		)
	}

	public func finishCredentialSetupCheck(_ check: CredentialSetupCheck) {
		releaseLease(for: check.hostId, id: check.id)
	}

	/// Waits for earlier host transactions, validates their committed
	/// generation, and retains the lease until the caller finishes the
	/// corresponding main-actor state transition.
	public func beginGenerationValidation(
		for hostId: UUID,
		expectedGeneration: UInt64
	) async throws -> CredentialGenerationValidation? {
		let leaseID = try await acquireLease(for: hostId)
		guard generation(for: hostId) == expectedGeneration else {
			releaseLease(for: hostId, id: leaseID)
			return nil
		}
		return CredentialGenerationValidation(id: leaseID, hostId: hostId)
	}

	public func finishGenerationValidation(
		_ validation: CredentialGenerationValidation
	) {
		releaseLease(for: validation.hostId, id: validation.id)
	}

	/// Applies remote bytes and returns a provisional commit while retaining
	/// the host lease. A newer local generation rejects the write after the
	/// lease is acquired, including local edits that were already queued.
	public func applyRemote(
		_ secrets: HostSecrets,
		for hostId: UUID,
		expectedGeneration: UInt64
	) async throws -> RemoteCredentialMaterialCommit? {
		let commitID = try await acquireLease(for: hostId)
		guard generation(for: hostId) == expectedGeneration else {
			releaseLease(for: hostId, id: commitID)
			return nil
		}

		var rollback: RollbackState?
		do {
			try Task.checkCancellation()
			let captured = try captureRollbackState(
				for: secrets,
				hostId: hostId
			)
			rollback = captured
			let managedPath = try await writeMaterial(
				secrets,
				hostId: hostId
			)
			let source = resolveRemoteSource(
				secrets,
				managedPath: managedPath
			)
			activeCommits[hostId] = ActiveCommit(
				id: commitID,
				rollback: captured,
				status: .provisional
			)
			return RemoteCredentialMaterialCommit(
				source: source,
				id: commitID,
				hostId: hostId
			)
		} catch {
			let originalError = error
			if let rollback {
				do {
					try await restore(rollback, hostId: hostId)
				} catch {
					advanceGeneration(for: hostId)
					logRollbackFailure(error, hostId: hostId)
				}
			}
			releaseLease(for: hostId, id: commitID)
			throw originalError
		}
	}

	public func resolveRemoteCommit(
		_ commit: RemoteCredentialMaterialCommit,
		as disposition: RemoteCredentialCommitDisposition
	) async throws {
		switch disposition {
		case .commit:
			guard isProvisionalCommit(id: commit.id, hostId: commit.hostId) else {
				return
			}
			advanceGeneration(for: commit.hostId)
			finishCommit(id: commit.id, hostId: commit.hostId)
		case .rollback:
			try await rollbackCommit(id: commit.id, hostId: commit.hostId)
		case .discard:
			try await discardCommit(id: commit.id, hostId: commit.hostId)
		}
	}

	/// Removes all credential material while retaining the host lease. The
	/// caller must finalize after host metadata persists, or roll back if that
	/// persistence fails.
	func beginDeletion(
		for hostId: UUID
	) async throws -> CredentialMaterialDeletionCommit {
		let commitID = try await acquireLease(for: hostId)
		var rollback: RollbackState?
		do {
			try Task.checkCancellation()
			let captured = try captureAllMaterialState(
				for: hostId
			)
			rollback = captured
			try secrets.deleteAll(
				prefix: SSHCredentialContract.accountPrefix(hostID: hostId)
			)
			try await managedKeyStore.delete(hostId: hostId)
			try Task.checkCancellation()
			activeCommits[hostId] = ActiveCommit(
				id: commitID,
				rollback: captured,
				status: .provisional
			)
			return CredentialMaterialDeletionCommit(
				id: commitID,
				hostId: hostId
			)
		} catch {
			let originalError = error
			if let rollback {
				do {
					try await restore(rollback, hostId: hostId)
				} catch {
					advanceGeneration(for: hostId)
					logRollbackFailure(error, hostId: hostId)
				}
			}
			releaseLease(for: hostId, id: commitID)
			throw originalError
		}
	}

	func finalizeDeletion(_ commit: CredentialMaterialDeletionCommit) {
		guard isProvisionalCommit(id: commit.id, hostId: commit.hostId) else {
			return
		}
		advanceGeneration(for: commit.hostId)
		finishCommit(id: commit.id, hostId: commit.hostId)
	}

	func rollbackDeletion(
		_ commit: CredentialMaterialDeletionCommit
	) async throws {
		try await rollbackCommit(id: commit.id, hostId: commit.hostId)
	}

	/// Establishes an account boundary around every per-host transaction, then
	/// removes managed private keys. Operations queued before the boundary are
	/// rejected so material from the old account cannot resume after the wipe.
	public func resetManagedKeysForAccountChange() async throws {
		let leaseID = try await acquireGlobalLease(
			rejectQueuedHostTransactions: true
		)
		defer {
			globalGeneration &+= 1
			releaseGlobalLease(id: leaseID)
		}
		try Task.checkCancellation()
		try await managedKeyStore.wipeAll()
	}

	#if DEBUG
	internal func waitingTransactionCount(for hostId: UUID) -> Int {
		leaseWaiters[hostId]?.count ?? 0
	}

	internal func waitingGlobalTransactionCount() -> Int {
		globalLeaseWaiters.count
	}
	#endif

	private func acquireLease(for hostId: UUID) async throws -> UUID {
		try Task.checkCancellation()
		let leaseID = UUID()
		guard activeGlobalLease != nil
			|| !globalLeaseWaiters.isEmpty
			|| activeLeases[hostId] != nil else {
			activeLeases[hostId] = leaseID
			do {
				try Task.checkCancellation()
				return leaseID
			} catch {
				releaseLease(for: hostId, id: leaseID)
				throw error
			}
		}

		do {
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation {
					(continuation: CheckedContinuation<Void, Error>) in
					if Task.isCancelled {
						continuation.resume(throwing: CancellationError())
					} else {
						leaseWaiters[hostId, default: []].append(
							LeaseWaiter(id: leaseID, continuation: continuation)
						)
					}
				}
			} onCancel: {
				Task {
					await self.cancelLeaseRequest(for: hostId, id: leaseID)
				}
			}
			try Task.checkCancellation()
			return leaseID
		} catch {
			cancelLeaseRequest(for: hostId, id: leaseID)
			throw error
		}
	}

	private func acquireGlobalLease(
		rejectQueuedHostTransactions: Bool
	) async throws -> UUID {
		try Task.checkCancellation()
		let leaseID = UUID()
		if rejectQueuedHostTransactions {
			rejectQueuedHostTransactionsForAccountReset()
		}

		guard activeGlobalLease != nil
			|| !globalLeaseWaiters.isEmpty
			|| !activeLeases.isEmpty else {
			activeGlobalLease = leaseID
			do {
				try Task.checkCancellation()
				return leaseID
			} catch {
				releaseGlobalLease(id: leaseID)
				throw error
			}
		}

		do {
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation {
					(continuation: CheckedContinuation<Void, Error>) in
					if Task.isCancelled {
						continuation.resume(throwing: CancellationError())
					} else {
						globalLeaseWaiters.append(
							GlobalLeaseWaiter(
								id: leaseID,
								continuation: continuation
							)
						)
					}
				}
			} onCancel: {
				Task {
					await self.cancelGlobalLeaseRequest(id: leaseID)
				}
			}
			try Task.checkCancellation()
			return leaseID
		} catch {
			cancelGlobalLeaseRequest(id: leaseID)
			throw error
		}
	}

	private func cancelLeaseRequest(for hostId: UUID, id: UUID) {
		if var waiters = leaseWaiters[hostId],
		   let index = waiters.firstIndex(where: { $0.id == id }) {
			let waiter = waiters.remove(at: index)
			leaseWaiters[hostId] = waiters.isEmpty ? nil : waiters
			waiter.continuation.resume(throwing: CancellationError())
			return
		}
		if activeLeases[hostId] == id {
			releaseLease(for: hostId, id: id)
		}
	}

	private func cancelGlobalLeaseRequest(id: UUID) {
		if let index = globalLeaseWaiters.firstIndex(where: { $0.id == id }) {
			let waiter = globalLeaseWaiters.remove(at: index)
			waiter.continuation.resume(throwing: CancellationError())
			resumeTransactionsAfterGlobalLeaseChange()
			return
		}
		if activeGlobalLease == id {
			releaseGlobalLease(id: id)
		}
	}

	private func releaseLease(for hostId: UUID, id: UUID) {
		guard activeLeases[hostId] == id else { return }
		activeLeases[hostId] = nil
		if !globalLeaseWaiters.isEmpty {
			if activeLeases.isEmpty, activeGlobalLease == nil {
				grantNextGlobalLease()
			}
			return
		}
		guard var waiters = leaseWaiters[hostId], !waiters.isEmpty else {
			leaseWaiters[hostId] = nil
			return
		}

		let next = waiters.removeFirst()
		activeLeases[hostId] = next.id
		leaseWaiters[hostId] = waiters.isEmpty ? nil : waiters
		next.continuation.resume()
	}

	private func releaseGlobalLease(id: UUID) {
		guard activeGlobalLease == id else { return }
		activeGlobalLease = nil
		resumeTransactionsAfterGlobalLeaseChange()
	}

	private func resumeTransactionsAfterGlobalLeaseChange() {
		guard activeGlobalLease == nil else { return }
		if activeLeases.isEmpty, !globalLeaseWaiters.isEmpty {
			grantNextGlobalLease()
			return
		}
		guard globalLeaseWaiters.isEmpty else { return }
		for hostId in Array(leaseWaiters.keys) where activeLeases[hostId] == nil {
			grantNextHostLease(for: hostId)
		}
	}

	private func grantNextGlobalLease() {
		guard activeGlobalLease == nil,
		      activeLeases.isEmpty,
		      !globalLeaseWaiters.isEmpty else {
			return
		}
		let next = globalLeaseWaiters.removeFirst()
		activeGlobalLease = next.id
		next.continuation.resume()
	}

	private func grantNextHostLease(for hostId: UUID) {
		guard activeGlobalLease == nil,
		      globalLeaseWaiters.isEmpty,
		      activeLeases[hostId] == nil,
		      var waiters = leaseWaiters[hostId],
		      !waiters.isEmpty else {
			return
		}
		let next = waiters.removeFirst()
		activeLeases[hostId] = next.id
		leaseWaiters[hostId] = waiters.isEmpty ? nil : waiters
		next.continuation.resume()
	}

	private func rejectQueuedHostTransactionsForAccountReset() {
		let queued = leaseWaiters.values.flatMap { $0 }
		leaseWaiters.removeAll()
		for waiter in queued {
			waiter.continuation.resume(
				throwing: SessionCredentialMaterialError.supersededByAccountReset
			)
		}
	}

	private func generation(for hostId: UUID) -> UInt64 {
		globalGeneration &+ generations[hostId, default: 0]
	}

	private func advanceGeneration(for hostId: UUID) {
		generations[hostId, default: 0] &+= 1
	}

	private func finishCommit(id: UUID, hostId: UUID) {
		guard isProvisionalCommit(id: id, hostId: hostId) else { return }
		activeCommits[hostId] = nil
		releaseLease(for: hostId, id: id)
	}

	private func rollbackCommit(id: UUID, hostId: UUID) async throws {
		guard let active = claimCommit(id: id, hostId: hostId) else { return }
		do {
			try await restore(active.rollback, hostId: hostId)
		} catch {
			advanceGeneration(for: hostId)
			finishClaimedCommit(id: id, hostId: hostId)
			throw error
		}
		finishClaimedCommit(id: id, hostId: hostId)
	}

	private func discardCommit(id: UUID, hostId: UUID) async throws {
		guard claimCommit(id: id, hostId: hostId) != nil else { return }
		var deletionError: Error?
		do {
			try secrets.deleteAll(
				prefix: SSHCredentialContract.accountPrefix(hostID: hostId)
			)
		} catch {
			deletionError = error
		}
		do {
			try await managedKeyStore.delete(hostId: hostId)
		} catch {
			if deletionError == nil { deletionError = error }
		}
		advanceGeneration(for: hostId)
		if let deletionError {
			finishClaimedCommit(id: id, hostId: hostId)
			throw deletionError
		}
		finishClaimedCommit(id: id, hostId: hostId)
	}

	private func isProvisionalCommit(id: UUID, hostId: UUID) -> Bool {
		guard let active = activeCommits[hostId], active.id == id else {
			return false
		}
		guard case .provisional = active.status else { return false }
		return true
	}

	private func claimCommit(id: UUID, hostId: UUID) -> ActiveCommit? {
		guard var active = activeCommits[hostId], active.id == id else {
			return nil
		}
		guard case .provisional = active.status else { return nil }
		active.status = .terminating
		activeCommits[hostId] = active
		return active
	}

	private func finishClaimedCommit(id: UUID, hostId: UUID) {
		guard let active = activeCommits[hostId], active.id == id else { return }
		guard case .terminating = active.status else { return }
		activeCommits[hostId] = nil
		releaseLease(for: hostId, id: id)
	}

	private func captureRollbackState(
		for secrets: HostSecrets,
		hostId: UUID
	) throws -> RollbackState {
		let wrotePassword = secrets.password != nil
		let wrotePassphrase = secrets.passphrase != nil
		let wrotePrivateKey = secrets.privateKeyBytes != nil
		return RollbackState(
			wrotePassword: wrotePassword,
			previousPassword: wrotePassword
				? try optionalSecret(account: SSHCredentialContract.account(
					hostID: hostId, kind: .password))
				: nil,
			wrotePassphrase: wrotePassphrase,
			previousPassphrase: wrotePassphrase
				? try optionalSecret(account: SSHCredentialContract.account(
					hostID: hostId, kind: .keyPassphrase))
				: nil,
			wrotePrivateKey: wrotePrivateKey,
			previousPrivateKey: wrotePrivateKey
				? try managedKeyStore.read(hostId: hostId)
				: nil
		)
	}

	private func captureAllMaterialState(
		for hostId: UUID
	) throws -> RollbackState {
		RollbackState(
			wrotePassword: true,
			previousPassword: try optionalSecret(
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .password)
			),
			wrotePassphrase: true,
			previousPassphrase: try optionalSecret(
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .keyPassphrase)
			),
			wrotePrivateKey: true,
			previousPrivateKey: try managedKeyStore.read(hostId: hostId)
		)
	}

	private func writeMaterial(
		_ secrets: HostSecrets,
		hostId: UUID
	) async throws -> String? {
		let managedPath: String?
		if let privateKeyBytes = secrets.privateKeyBytes {
			managedPath = try await managedKeyStore.write(
				hostId: hostId,
				bytes: privateKeyBytes
			).path
			try Task.checkCancellation()
		} else {
			managedPath = nil
		}
		try writeSecrets(secrets, for: hostId)
		try Task.checkCancellation()
		return managedPath
	}

	private func resolveLocalSource(
		_ source: LocalCredentialSource,
		managedPath: String?
	) -> LocalCredentialSource {
		guard let managedPath else { return source }
		guard case let .keyFile(_, hasPassphrase) = source else { return source }
		return .keyFile(path: managedPath, hasPassphrase: hasPassphrase)
	}

	private func resolveRemoteSource(
		_ secrets: HostSecrets,
		managedPath: String?
	) -> RemoteCredentialSource {
		if let managedPath {
			return .keyFile(
				path: managedPath,
				hasPassphrase: secrets.passphrase != nil
			)
		}
		return secrets.password == nil ? .unchanged : .password
	}

	private func restore(
		_ rollback: RollbackState,
		hostId: UUID
	) async throws {
		var firstError: Error?
		do {
			try restoreSecret(
				rollback.previousPassword,
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .password),
				wasWritten: rollback.wrotePassword
			)
		} catch {
			firstError = error
		}
		do {
			try restoreSecret(
				rollback.previousPassphrase,
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .keyPassphrase),
				wasWritten: rollback.wrotePassphrase
			)
		} catch {
			if firstError == nil { firstError = error }
		}
		if rollback.wrotePrivateKey {
			if let previousPrivateKey = rollback.previousPrivateKey {
				do {
					_ = try await managedKeyStore.write(
						hostId: hostId,
						bytes: previousPrivateKey
					)
				} catch {
					if firstError == nil { firstError = error }
				}
			} else {
				do {
					try await managedKeyStore.delete(hostId: hostId)
				} catch {
					if firstError == nil { firstError = error }
				}
			}
		}
		if let firstError { throw firstError }
	}

	private func writeSecrets(_ secrets: HostSecrets, for hostId: UUID) throws {
		if let password = secrets.password {
			try setSecret(
				password,
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .password)
			)
		}
		if let passphrase = secrets.passphrase {
			try setSecret(
				passphrase,
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .keyPassphrase)
			)
		}
	}

	private func optionalSecret(
		account: String,
		interaction: KeychainReadInteraction = .userInitiated
	) throws -> Data? {
		do {
			return try secrets.get(
				account: account,
				interaction: interaction
			).data(using: .utf8)
		} catch KeychainError.notFound {
			return nil
		}
	}

	private func hasSecret(
		account: String,
		interaction: KeychainReadInteraction
	) throws -> Bool {
		do {
			_ = try secrets.get(account: account, interaction: interaction)
			return true
		} catch KeychainError.notFound {
			return false
		}
	}

	private func setSecret(_ data: Data, account: String) throws {
		guard let value = String(data: data, encoding: .utf8) else {
			throw KeychainError.decodeFailed
		}
		try secrets.set(account: account, secret: value)
	}

	private func restoreSecret(
		_ data: Data?,
		account: String,
		wasWritten: Bool
	) throws {
		guard wasWritten else { return }
		if let data {
			try setSecret(data, account: account)
		} else {
			do {
				try secrets.delete(account: account)
			} catch KeychainError.notFound {
				return
			}
		}
	}

	private func logRollbackFailure(_ error: Error, hostId: UUID) {
		let description = String(describing: error)
		Self.log.error(
			"credential rollback failed: \(hostId, privacy: .public): \(description, privacy: .public)"
		)
	}
}
