import Foundation
import HostRepositoryCore
import ServerSyncClient
import SSHCommandBuilder
import Testing

@Test("Remote insertion resolves and backfills Jump Host identities")
private func remoteInsertionResolvesJumpHostIdentities() throws {
	let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
	let child = SSHHost(
		name: "Production",
		hostname: "prod.internal",
		username: "deploy",
		credential: .agent,
		jumpHostServerId: "server-bastion"
	)
	let remote = RemoteHost(
		id: "server-bastion",
		name: "Bastion",
		hostname: "bastion.example.com",
		port: 2222,
		username: "deploy",
		authType: "password",
		createdAt: timestamp,
		updatedAt: timestamp
	)
	let localID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000041"))

	let result = HostRepositoryProjection.inserting(
		remote,
		localID: localID,
		into: [child]
	)

	let inserted = try #require(result.hosts.first(where: { $0.id == localID }))
	let updatedChild = try #require(result.hosts.first(where: { $0.id == child.id }))
	#expect(result.localID == localID)
	#expect(inserted.serverId == remote.id)
	#expect(inserted.credential == .password)
	#expect(inserted.createdAt == timestamp)
	#expect(updatedChild.jumpHostId == localID)
}

@Test("Remote metadata projection preserves device-local credential state")
private func remoteMetadataProjectionPreservesCredentialState() throws {
	let automation = HostAutomation(
		isEnabled: true,
		startupSnippetID: UUID(),
		environment: [
			HostEnvironmentVariable(name: "REGION", value: "west")
		]
	)
	let bastion = SSHHost(
		serverId: "server-bastion",
		name: "Bastion",
		hostname: "bastion.example.com",
		username: "deploy",
		credential: .agent
	)
	let local = SSHHost(
		serverId: "server-prod",
		name: "Old",
		hostname: "old.example.com",
		username: "root",
		credential: .keyFile(keyPath: "/device/key", hasPassphrase: true),
		credentialMaterialDirty: true
	)
	let remote = RemoteHost(
		id: "server-prod",
		name: "Production",
		hostname: "prod.internal",
		port: 2200,
		username: "deploy",
		authType: "password",
		createdAt: local.createdAt,
		updatedAt: local.updatedAt.addingTimeInterval(60),
		jumpHostServerId: "server-bastion",
		automation: automation
	)

	let result = try #require(HostRepositoryProjection.applying(
		remote,
		to: local.id,
		in: [local, bastion]
	))
	let updated = try #require(result.first(where: { $0.id == local.id }))

	#expect(updated.name == "Production")
	#expect(updated.hostname == "prod.internal")
	#expect(updated.port == 2200)
	#expect(updated.jumpHostId == bastion.id)
	#expect(updated.credential == local.credential)
	#expect(updated.credentialMaterialDirty)
	#expect(updated.automation == automation)
}

@Test("Server identity projection updates dependent Jump Host references atomically")
private func serverIdentityProjectionUpdatesDependents() throws {
	let parent = SSHHost(
		name: "Bastion",
		hostname: "bastion.example.com",
		username: "deploy",
		credential: .agent
	)
	let child = SSHHost(
		name: "Production",
		hostname: "prod.internal",
		username: "deploy",
		credential: .agent,
		jumpHostId: parent.id
	)
	let timestamp = Date(timeIntervalSince1970: 1_700_000_100)

	let result = try #require(HostRepositoryProjection.assigning(
		serverID: "server-bastion",
		to: parent.id,
		in: [parent, child],
		at: timestamp
	))
	let updatedParent = try #require(result.first(where: { $0.id == parent.id }))
	let updatedChild = try #require(result.first(where: { $0.id == child.id }))

	#expect(updatedParent.serverId == "server-bastion")
	#expect(updatedParent.updatedAt == timestamp)
	#expect(updatedChild.jumpHostServerId == "server-bastion")
	#expect(updatedChild.updatedAt == timestamp)
}
