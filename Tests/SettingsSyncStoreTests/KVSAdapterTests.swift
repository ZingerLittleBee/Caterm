import XCTest
@testable import SettingsSyncStore

final class KVSAdapterTests: XCTestCase {
	func test_classify_mapsKnownReasons() {
		XCTAssertEqual(KVSReasonClassifier.classify(0), .serverChange)
		XCTAssertEqual(KVSReasonClassifier.classify(1), .initialSyncChange)
		XCTAssertEqual(KVSReasonClassifier.classify(2), .quotaViolationChange)
		XCTAssertEqual(KVSReasonClassifier.classify(3), .accountChange)
		XCTAssertEqual(KVSReasonClassifier.classify(99), .unknown(99))
	}

	func test_classify_handlesNilAsUnknown() {
		XCTAssertEqual(KVSReasonClassifier.classify(nil), .unknown(-1))
	}

	func test_fakeKVS_setAndGet_roundTrip() {
		let kvs = FakeKVS()
		let payload = "hello".data(using: .utf8)!
		kvs.set(payload, forKey: "test")
		XCTAssertEqual(kvs.data(forKey: "test"), payload)
		XCTAssertTrue(kvs.synchronize())
	}

	func test_fakeKVS_remove() {
		let kvs = FakeKVS()
		kvs.set(Data([1]), forKey: "k")
		kvs.removeObject(forKey: "k")
		XCTAssertNil(kvs.data(forKey: "k"))
	}

	func test_fakeKVS_dictionaryRepresentation() {
		let kvs = FakeKVS()
		kvs.set(Data([1]), forKey: "a")
		kvs.set(Data([2]), forKey: "b")
		let rep = kvs.dictionaryRepresentation()
		XCTAssertEqual((rep["a"] as? Data), Data([1]))
		XCTAssertEqual((rep["b"] as? Data), Data([2]))
	}
}
