import CloudKit
import Foundation
import os

public protocol AccountSensitiveClient: Sendable {
	func resetHostSyncState() async
	func deleteHostSubscription() async throws
}

extension CloudKitSyncClient: AccountSensitiveClient {}

public actor AccountIdentityTracker {
	private static let storageKey = "cloudkit.lastKnownUserRecordName"
	private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-account")

	private let defaults: UserDefaults
	private let currentUserRecordIDProvider: @Sendable () async -> CKRecord.ID?
	private let tokensExistProvider: @Sendable () async -> Bool

	public init(defaults: UserDefaults = .standard,
	            currentUserRecordID: @escaping @Sendable () async -> CKRecord.ID?,
	            tokensExist: @escaping @Sendable () async -> Bool) {
		self.defaults = defaults
		self.currentUserRecordIDProvider = currentUserRecordID
		self.tokensExistProvider = tokensExist
	}

	public func handleAccountChange(client: any AccountSensitiveClient) async {
		let prior = defaults.string(forKey: Self.storageKey)
		let current = await currentUserRecordIDProvider()?.recordName

		switch (prior, current) {
		case (nil, nil):
			return
		// First observation of an identity with tokens already on disk
		// means a prior install left CKServerChangeTokens behind. They
		// belong to whichever account that prior install was signed in
		// to — possibly different from `new`. Drop them to force a
		// forceFull pass on first sync of the current account.
		case (nil, .some(let new)):
			if await tokensExistProvider() {
				Self.log.info("first identity observation with existing tokens → resetting")
				await client.resetHostSyncState()
			}
			defaults.set(new, forKey: Self.storageKey)
		case (.some(let p), .some(let c)) where p == c:
			return
		case (.some, _):
			await client.resetHostSyncState()
			try? await client.deleteHostSubscription()
			if let new = current {
				defaults.set(new, forKey: Self.storageKey)
			} else {
				defaults.removeObject(forKey: Self.storageKey)
			}
		}
	}
}

extension CloudKitSyncClient {
	public func hasAnyHostSyncTokens() async -> Bool {
		await tokenStore.loadDatabaseToken() != nil
	}
}
