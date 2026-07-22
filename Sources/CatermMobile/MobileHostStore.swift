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

	private let fileURL: URL
	private let localMutationsSubject = PassthroughSubject<Void, Never>()
	private var deletionOutbox: HostDeletionOutbox

	public init(fileURL: URL) {
		self.fileURL = fileURL
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

	public func delete(id: UUID) throws {
		try delete(id: id, enqueueRemoteDeletion: true)
	}

	/// Replace the whole list and persist. The mobile shell mutates hosts
	/// through a plain `Binding<[SSHHost]>` (append/remove/replace), so a
	/// single persisting setter is the seam that keeps every UI edit on
	/// disk without threading store calls through every view.
	public func replaceAll(_ newHosts: [SSHHost]) {
		do {
			try persist(newHosts)
		} catch {
			return
		}
		hosts = newHosts
		localMutationsSubject.send()
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

	private func delete(id: UUID, enqueueRemoteDeletion: Bool) throws {
		guard let host = hosts.first(where: { $0.id == id }) else { return }
		let serverID = enqueueRemoteDeletion ? host.serverId : nil
		let inserted = try serverID.map { try deletionOutbox.insert($0) } ?? false
		var updated = hosts
		updated.removeAll { $0.id == id }
		do {
			try persist(updated)
		} catch {
			if inserted, let serverID {
				try? deletionOutbox.remove(serverID)
			}
			throw error
		}
		hosts = updated
		if enqueueRemoteDeletion {
			localMutationsSubject.send()
		}
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
		try delete(id: id, enqueueRemoteDeletion: true)
	}

	public func pendingRemoteDeletionIDs() throws -> [String] {
		try deletionOutbox.pendingIDs()
	}

	public func clearPendingRemoteDeletion(serverID: String) throws {
		try deletionOutbox.remove(serverID)
	}

	public func createHostFromRemote(_ remote: RemoteHost) throws -> UUID {
		let host = SSHHost(
			serverId: remote.id,
			name: remote.name,
			hostname: remote.hostname,
			port: remote.port,
			username: remote.username,
			credential: .password,
			createdAt: remote.createdAt,
			updatedAt: remote.updatedAt,
			jumpHostId: hosts.first(where: {
				$0.serverId == remote.jumpHostServerId
			})?.id,
			jumpHostServerId: remote.jumpHostServerId,
			forwards: remote.forwards,
			icon: remote.icon,
			organization: remote.organization
		)
		var updated = hosts
		updated.append(host)
		for index in updated.indices where
			updated[index].jumpHostServerId == remote.id {
			updated[index].jumpHostId = host.id
		}
		try persist(updated)
		hosts = updated
		return host.id
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) throws {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		updated[index].name = remote.name
		updated[index].hostname = remote.hostname
		updated[index].port = remote.port
		updated[index].username = remote.username
		updated[index].updatedAt = remote.updatedAt
		updated[index].jumpHostId = updated.first(where: {
			$0.serverId == remote.jumpHostServerId
		})?.id
		updated[index].jumpHostServerId = remote.jumpHostServerId
		updated[index].forwards = remote.forwards
		updated[index].icon = remote.icon
		updated[index].organization = remote.organization
		try persist(updated)
		hosts = updated
	}

	public func assignServerID(_ serverID: String, to localID: UUID) throws {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			throw StoreError.hostNotFound
		}
		var updated = hosts
		let timestamp = Date()
		updated[index].serverId = serverID
		updated[index].updatedAt = timestamp
		for childIndex in updated.indices where
			updated[childIndex].id != localID &&
			updated[childIndex].jumpHostId == localID &&
			updated[childIndex].jumpHostServerId != serverID {
			updated[childIndex].jumpHostServerId = serverID
			updated[childIndex].updatedAt = timestamp
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
		try delete(id: localID, enqueueRemoteDeletion: false)
	}
}
