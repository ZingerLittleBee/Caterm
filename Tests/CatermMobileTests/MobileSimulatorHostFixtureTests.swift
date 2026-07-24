import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileSimulatorHostFixtureTests: XCTestCase {
	func testAutomationFixtureBuildsReviewableHostAndStableSnippet() throws {
		let fixture = try XCTUnwrap(MobileSimulatorHostFixture(environment: [
			"CATERM_SIM_CACHED_HOST_NAME": "Automation E2E",
			"CATERM_SIM_CACHED_HOST_ADDRESS": "127.0.0.1",
			"CATERM_SIM_CACHED_HOST_PORT": "2223",
			"CATERM_SIM_CACHED_HOST_USER": "caterm",
			"CATERM_SIM_CACHED_HOST_AUTH": "password",
			"CATERM_SIM_AUTOMATION_COMMAND": "printf 'CATERM_AUTOMATION_OK\\n'",
			"CATERM_SIM_AUTOMATION_ACCEPTED_NAME": "CATERM_ACCEPTED",
			"CATERM_SIM_AUTOMATION_ACCEPTED_VALUE": "yes",
			"CATERM_SIM_AUTOMATION_REJECTED_NAME": "CATERM_REJECTED",
			"CATERM_SIM_AUTOMATION_REJECTED_VALUE": "no",
		]))

		XCTAssertEqual(fixture.host.name, "Automation E2E")
		XCTAssertEqual(fixture.host.hostname, "127.0.0.1")
		XCTAssertEqual(fixture.host.port, 2223)
		XCTAssertEqual(fixture.host.username, "caterm")
		XCTAssertEqual(fixture.host.credential, .password)
		XCTAssertEqual(fixture.snippet?.id, MobileSimulatorHostFixture.snippetID)
		XCTAssertEqual(
			fixture.snippet?.content,
			"printf 'CATERM_AUTOMATION_OK\\n'"
		)
		XCTAssertTrue(fixture.host.automation.isEnabled)
		XCTAssertEqual(
			fixture.host.automation.startupSnippetID,
			MobileSimulatorHostFixture.snippetID
		)
		XCTAssertEqual(
			fixture.host.automation.environment.map {
				"\($0.name)=\($0.value)"
			},
			["CATERM_ACCEPTED=yes", "CATERM_REJECTED=no"]
		)
		XCTAssertEqual(fixture.host.automation.reviewPolicy, .always)
		XCTAssertEqual(
			fixture.host.automation.reconnectPolicy,
			.everyConnection
		)
	}

	func testFixtureWithoutAutomationCommandKeepsAutomationDisabled() throws {
		let fixture = try XCTUnwrap(MobileSimulatorHostFixture(environment: [
			"CATERM_SIM_CACHED_HOST_NAME": "Plain E2E",
		]))

		XCTAssertNil(fixture.snippet)
		XCTAssertEqual(fixture.host.automation, .disabled)
	}

	func testFixtureRequiresHostName() {
		XCTAssertNil(MobileSimulatorHostFixture(environment: [:]))
	}
}
