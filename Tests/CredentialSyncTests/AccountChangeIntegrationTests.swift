import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import ManagedKeyStore
import XCTest
@testable import CredentialSync

@MainActor
final class AccountChangeIntegrationTests: XCTestCase {
	private var tmpDir: URL!
	private var defaultsSuite: String!
	private var defaults: UserDefaults!

	override func setUp() async throws {
		tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("AccountChangeIntegrationTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
		defaultsSuite = "AccountChangeIntegrationTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: defaultsSuite)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: tmpDir)
		UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
	}

	func test_resetForAccountChange_wipesManagedKeys_clearsState() async throws {
		// Pre-state: enabled, with managed key + populated prefs
		let managedKeyStore = ManagedKeyStore(rootURL: tmpDir)
		let hostId = UUID()
		let bytes = Data("PRIVATE-KEY-BYTES".utf8)
		_ = try await managedKeyStore.write(hostId: hostId, bytes: bytes)
		// Sanity: file exists.
		XCTAssertNotNil(try managedKeyStore.read(hostId: hostId))

		let prefsStore = CredentialSyncPreferencesStore(defaults: defaults)
		prefsStore.mutate {
			$0.state = .enabled
			$0.lastAppliedRevision = [hostId: 7]
			$0.credentialsNeedFullScan = true
			$0.corruptCredentials = []
		}

		let coordinator = CredentialSyncAccountResetCoordinator(
			prefsStore: prefsStore,
			managedKeyStore: managedKeyStore
		)

		await coordinator.resetForAccountChange()

		// Managed key wiped (file gone).
		XCTAssertNil(try managedKeyStore.read(hostId: hostId))

		// Prefs reset to defaults.
		XCTAssertEqual(prefsStore.prefs.state, .disabled)
		XCTAssertTrue(prefsStore.prefs.lastAppliedRevision.isEmpty)
		XCTAssertFalse(prefsStore.prefs.credentialsNeedFullScan)
		XCTAssertNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress)
		XCTAssertTrue(prefsStore.prefs.corruptCredentials.isEmpty)
	}

	func test_resetForAccountChange_isIdempotent() async throws {
		// Calling on a fresh/disabled state must not throw or alter anything.
		let managedKeyStore = ManagedKeyStore(rootURL: tmpDir)
		let prefsStore = CredentialSyncPreferencesStore(defaults: defaults)
		let coordinator = CredentialSyncAccountResetCoordinator(
			prefsStore: prefsStore,
			managedKeyStore: managedKeyStore
		)

		await coordinator.resetForAccountChange()
		// Run again — must still be safe.
		await coordinator.resetForAccountChange()

		XCTAssertEqual(prefsStore.prefs.state, .disabled)
	}
}
