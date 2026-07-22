import CloudKit
import CloudKitSyncClient
import Foundation
import ServerSyncClient
import SettingsSyncStore
import SnippetSyncClient

struct CloudSyncBootstrap {
	let accountSession: any AuthSessionProtocol & AccountSessionProviding
	let hostClient: any IncrementalHostSyncClient
	let snippetClient: any IncrementalSnippetSyncClient
	let cloudKitClient: CloudKitSyncClient?
	let accountIdentityTracker: AccountIdentityTracker?
	let startObservingAccountChanges: @MainActor () -> Void

	@MainActor
	static func make(
		disabled: Bool,
		cloudContainerFactory: () -> CKContainer = {
			CKContainer(identifier: "iCloud.com.caterm.app")
		}
	) -> CloudSyncBootstrap {
		if disabled {
			let disabledClient = DisabledCloudSyncClient()
			return CloudSyncBootstrap(
				accountSession: DisabledCloudAccountSession(),
				hostClient: disabledClient,
				snippetClient: disabledClient,
				cloudKitClient: nil,
				accountIdentityTracker: nil,
				startObservingAccountChanges: {}
			)
		}

		let cloudContainer = cloudContainerFactory()
		let session = iCloudAccountSession(provider: cloudContainer)
		let client = CloudKitSyncClient(database: cloudContainer.privateCloudDatabase)
		let tracker = AccountIdentityTracker(
			currentUserRecordID: { try? await cloudContainer.userRecordID() },
			tokensExist: {
				let hostTokens = await client.hasAnyHostSyncTokens()
				let snippetTokens = await client.hasAnySnippetSyncTokens()
				return hostTokens || snippetTokens
			}
		)
		return CloudSyncBootstrap(
			accountSession: session,
			hostClient: client,
			snippetClient: client,
			cloudKitClient: client,
			accountIdentityTracker: tracker,
			startObservingAccountChanges: { session.startObservingAccountChanges() }
		)
	}
}

@MainActor
private final class DisabledCloudAccountSession: AuthSessionProtocol, AccountSessionProviding {
	let isSignedIn = false

	func refresh() async {}
}

private final class DisabledCloudSyncClient: IncrementalHostSyncClient, IncrementalSnippetSyncClient {
	func listHosts() async throws -> [RemoteHost] { [] }

	func createHost(_: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		throw ServerSyncError.notSignedIn
	}

	func updateHost(_: RemoteHostUpdateInput) async throws {
		throw ServerSyncError.notSignedIn
	}

	func deleteHost(id _: String) async throws {
		throw ServerSyncError.notSignedIn
	}

	func preferredHostSyncMode() async -> HostSyncMode { .incremental }

	func fetchHostChanges() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .incremental
		)
	}

	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}

	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}

	func resetHostSyncState() async {}

	func ensureHostSubscription() async throws {}

	func deleteHostSubscription() async throws {}

	func preferredSnippetSyncMode() async -> SnippetSyncMode { .incremental }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		SnippetChangeBatch(
			changedSnippets: [],
			deletedSnippetIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .incremental
		)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		SnippetChangeBatch(
			changedSnippets: [],
			deletedSnippetIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}

	func commitSnippetCheckpoint(_: any SnippetSyncCheckpoint) async throws {}

	func resetSnippetSyncState() async {}

	func ensureSnippetSubscription() async throws {}

	func deleteSnippetSubscription() async throws {}

	func pushSnippet(_: Snippet) async throws -> Snippet {
		throw ServerSyncError.notSignedIn
	}

	func deleteSnippet(id _: UUID) async throws {
		throw ServerSyncError.notSignedIn
	}

	func hasAnySnippetSyncTokens() async -> Bool { false }
}
