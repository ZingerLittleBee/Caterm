@testable import CatermMobileTerminal
import XCTest

final class TerminalKeyBarSmokeTests: XCTestCase {
	func testModuleLinks() {
		XCTAssertEqual(TerminalKeyBar.moduleName, "CatermMobileTerminal")
	}
}
