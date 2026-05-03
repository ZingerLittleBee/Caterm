import XCTest
@testable import SettingsSyncStore

final class IdentityTokenStoreTests: XCTestCase {
	/// Conforms only to NSCoding & NSCopying & NSObjectProtocol, NOT NSSecureCoding.
	/// This is the regression guard against accidentally re-enabling
	/// requiringSecureCoding on the archive call.
	@objc(IdentityTokenStoreTests_NonSecureFakeToken)
	final class NonSecureFakeToken: NSObject, NSCoding, NSCopying {
		let payload: String
		init(_ p: String) { self.payload = p }
		required init?(coder: NSCoder) {
			self.payload = coder.decodeObject(forKey: "p") as? String ?? ""
		}
		func encode(with coder: NSCoder) { coder.encode(payload, forKey: "p") }
		func copy(with zone: NSZone? = nil) -> Any { NonSecureFakeToken(payload) }
		override func isEqual(_ object: Any?) -> Bool {
			(object as? NonSecureFakeToken)?.payload == payload
		}
	}

	private func makeDefaults() -> UserDefaults {
		let suite = "test-\(UUID().uuidString)"
		return UserDefaults(suiteName: suite)!
	}

	func test_archiveAndUnarchive_roundTripWithoutSecureCoding() throws {
		let defaults = makeDefaults()
		let store = IdentityTokenStore(userDefaults: defaults)
		let token = NonSecureFakeToken("user-A")

		store.persist(token)
		let loaded = store.loadPersisted()
		guard case .token(let unarchived) = loaded else {
			XCTFail("expected .token, got \(loaded)")
			return
		}
		XCTAssertTrue(unarchived.isEqual(token))
	}

	func test_isEqual_acrossArchiveBoundary() throws {
		let defaults = makeDefaults()
		let store = IdentityTokenStore(userDefaults: defaults)
		let a = NonSecureFakeToken("X")
		let b = NonSecureFakeToken("Y")

		store.persist(a)
		guard case .token(let unarchivedA) = store.loadPersisted() else {
			XCTFail("expected .token"); return
		}
		XCTAssertTrue(unarchivedA.isEqual(a))
		XCTAssertFalse(unarchivedA.isEqual(b))
	}

	func test_loadPersisted_returnsNil_whenNothingStored() {
		let defaults = makeDefaults()
		let store = IdentityTokenStore(userDefaults: defaults)
		XCTAssertEqual(store.loadPersisted(), .none)
	}

	func test_loadPersisted_returnsArchiveFailedSentinel_whenSentinelStored() {
		let defaults = makeDefaults()
		let store = IdentityTokenStore(userDefaults: defaults)
		store.persistSentinel()
		XCTAssertEqual(store.loadPersisted(), .archiveFailed)
	}

	func test_loadPersisted_returnsNil_whenDataIsCorrupted() {
		let defaults = makeDefaults()
		let store = IdentityTokenStore(userDefaults: defaults)
		defaults.set(Data([0xFF, 0xFE, 0xFD]), forKey: IdentityTokenStore.userDefaultsKey)
		XCTAssertEqual(store.loadPersisted(), .none)
	}
}
