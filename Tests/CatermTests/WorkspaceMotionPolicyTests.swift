import XCTest
@testable import Caterm

final class WorkspaceMotionPolicyTests: XCTestCase {
	func testReduceMotionDisablesNonessentialPresentationAnimation() {
		XCTAssertNil(WorkspaceMotionPolicy.presentationAnimation(reduceMotion: true))
		XCTAssertNil(WorkspaceMotionPolicy.statusAnimation(reduceMotion: true))
	}

	func testDefaultMotionKeepsShortContextualAnimations() {
		XCTAssertNotNil(WorkspaceMotionPolicy.presentationAnimation(reduceMotion: false))
		XCTAssertNotNil(WorkspaceMotionPolicy.statusAnimation(reduceMotion: false))
	}
}
