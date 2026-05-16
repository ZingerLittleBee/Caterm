import XCTest
@testable import SettingsSyncStore

@MainActor
final class TokenClassificationTests: XCTestCase {
	private func classifier(_ persisted: PersistedTokenLoad,
	                        _ current: (NSObject & NSCoding & NSCopying)?) -> TokenClassification {
		return TokenClassifier.classify(persisted: persisted, current: current)
	}

	func test_bothNil_isNotSignedIn() {
		XCTAssertEqual(classifier(.none, nil), .notSignedIn)
	}

	func test_persistedNoneAndCurrentNonNil_isFirstObservation() {
		let t = TestToken("X")
		XCTAssertEqual(classifier(.none, t), .firstObservation)
	}

	func test_persistedTokenAndCurrentNil_isSignedOut() {
		let prev = TestToken("X")
		XCTAssertEqual(classifier(.token(prev), nil), .signedOut)
	}

	func test_persistedAndCurrent_equal_isIdentitySame() {
		let prev = TestToken("X")
		let curr = TestToken("X")
		XCTAssertEqual(classifier(.token(prev), curr), .identitySame)
	}

	func test_persistedAndCurrent_different_isIdentityChanged() {
		let prev = TestToken("X")
		let curr = TestToken("Y")
		XCTAssertEqual(classifier(.token(prev), curr), .identityChanged)
	}

	func test_archiveFailedSentinel_isUnknownPrevious_regardlessOfCurrent() {
		XCTAssertEqual(classifier(.archiveFailed, nil), .unknownPrevious)
		XCTAssertEqual(classifier(.archiveFailed, TestToken("Z")), .unknownPrevious)
	}
}
