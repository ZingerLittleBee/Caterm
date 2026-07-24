import CloudKit
import Foundation
import os

public protocol AccountSensitiveClient: Sendable {
	func resetHostSyncState() async
	func deleteHostSubscription() async throws
	func resetSnippetSyncState() async
	func deleteSnippetSubscription() async throws
}

extension CloudKitSyncClient: AccountSensitiveClient {}

public enum AccountChangeOutcome: Sendable, Equatable {
	/// No-op: same identity as last observed, or no identity in either state.
	case unchanged
	/// First-ever observation of an identity (prior was nil).
	case firstObservation
	/// Identity actually changed (prior non-nil, current differs OR is nil).
	case identityChanged
	/// CloudKit could not determine the account identity. Cached account data
	/// must remain untouched until a later observation succeeds.
	case temporarilyUnavailable(String)
}

public enum AccountIdentityObservation: Sendable, Equatable {
	case signedIn(CKRecord.ID)
	case signedOut
	case temporarilyUnavailable(String)
}

public protocol CKAccountIdentityProviding: CKAccountStatusProviding {
	func userRecordID() async throws -> CKRecord.ID
}

extension CKContainer: CKAccountIdentityProviding {}

public enum CloudKitAccountIdentityObserver {
	public static func observe(
		provider: any CKAccountIdentityProviding
	) async -> AccountIdentityObservation {
		let status: CKAccountStatus
		do {
			status = try await provider.accountStatus()
		} catch {
			return .temporarilyUnavailable(error.localizedDescription)
		}

		switch status {
		case .available:
			do {
				return .signedIn(try await provider.userRecordID())
			} catch let error as CKError where error.code == .notAuthenticated {
				return .signedOut
			} catch {
				return .temporarilyUnavailable(error.localizedDescription)
			}
		case .noAccount, .restricted:
			return .signedOut
		case .couldNotDetermine:
			return .temporarilyUnavailable("iCloud account status could not be determined.")
		case .temporarilyUnavailable:
			return .temporarilyUnavailable("iCloud account is temporarily unavailable.")
		@unknown default:
			return .temporarilyUnavailable("iCloud account status is unsupported.")
		}
	}
}

public actor AccountIdentityTracker {
	private enum PendingIdentity {
		case signedIn(String)
		case signedOut
	}

	private static let storageKey = "cloudkit.lastKnownUserRecordName"
	private static let pendingUnknownIdentityKey =
		"cloudkit.pendingUnknownUserRecordName"
	private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-account")

	private let defaults: UserDefaults
	private let currentIdentityProvider: @Sendable () async -> AccountIdentityObservation
	private let tokensExistProvider: @Sendable () async -> Bool
	private var pendingIdentity: PendingIdentity?

	public init(defaults: UserDefaults = .standard,
	            currentUserRecordID: @escaping @Sendable () async -> CKRecord.ID?,
	            tokensExist: @escaping @Sendable () async -> Bool) {
		self.defaults = defaults
		self.currentIdentityProvider = {
			if let identity = await currentUserRecordID() {
				return .signedIn(identity)
			}
			return .signedOut
		}
		self.tokensExistProvider = tokensExist
	}

	public init(defaults: UserDefaults = .standard,
	            currentIdentity: @escaping @Sendable () async -> AccountIdentityObservation,
	            tokensExist: @escaping @Sendable () async -> Bool) {
		self.defaults = defaults
		self.currentIdentityProvider = currentIdentity
		self.tokensExistProvider = tokensExist
	}

	@discardableResult
	public func handleAccountChange(client: any AccountSensitiveClient) async -> AccountChangeOutcome {
		let prior = defaults.string(forKey: Self.storageKey)
		let current: String?
		switch await currentIdentityProvider() {
		case .signedIn(let identity):
			current = identity.recordName
		case .signedOut:
			current = nil
		case .temporarilyUnavailable(let message):
			return .temporarilyUnavailable(message)
		}

		switch (prior, current) {
		case (nil, nil):
			return .unchanged
		case (nil, .some(let new)):
			let hasUnknownIdentityState: Bool
			if defaults.string(forKey: Self.pendingUnknownIdentityKey) != nil {
				hasUnknownIdentityState = true
			} else {
				hasUnknownIdentityState = await tokensExistProvider()
			}
			if hasUnknownIdentityState {
				Self.log.info("first identity observation with existing state → isolating host AND snippet")
				defaults.set(new, forKey: Self.pendingUnknownIdentityKey)
				await client.resetHostSyncState()
				await client.resetSnippetSyncState()
				try? await client.deleteHostSubscription()
				try? await client.deleteSnippetSubscription()
				pendingIdentity = .signedIn(new)
				return .identityChanged
			}
			defaults.removeObject(forKey: Self.pendingUnknownIdentityKey)
			defaults.set(new, forKey: Self.storageKey)
			return .firstObservation
		case (.some(let p), .some(let c)) where p == c:
			return .unchanged
		case (.some, _):
			await client.resetHostSyncState()
			await client.resetSnippetSyncState()
			try? await client.deleteHostSubscription()
			try? await client.deleteSnippetSubscription()
			if let new = current {
				pendingIdentity = .signedIn(new)
			} else {
				pendingIdentity = .signedOut
			}
			return .identityChanged
		}
	}

	/// Commits the identity observed by the most recent `.identityChanged`
	/// result. Call only after every account-scoped local reset succeeds. Until
	/// then the previous identity remains durable, so a later notification or
	/// app launch detects the same transition and retries it.
	public func acknowledgeIdentityChange() {
		guard let pendingIdentity else { return }
		switch pendingIdentity {
		case .signedIn(let recordName):
			defaults.set(recordName, forKey: Self.storageKey)
		case .signedOut:
			defaults.removeObject(forKey: Self.storageKey)
		}
		defaults.removeObject(forKey: Self.pendingUnknownIdentityKey)
		self.pendingIdentity = nil
	}
}

extension CloudKitSyncClient {
	public func hasAnyHostSyncTokens() async -> Bool {
		await tokenStore.loadDatabaseToken() != nil
	}
}
