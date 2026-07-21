import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

final class HostOrganizationTests: XCTestCase {
	func testTextInputBuildsNormalizedOrganization() {
		let organization = HostOrganizationText.makeOrganization(
			group: " Production / API ",
			tags: " Linux, critical, linux \n on-call "
		)

		XCTAssertEqual(organization.groupPath, ["Production", "API"])
		XCTAssertEqual(organization.tags, ["Linux", "critical", "on-call"])
	}

	func testFilterCombinesSearchGroupAndTag() {
		let production = SSHHost(
			name: "API", hostname: "api.example", username: "deploy",
			credential: .agent,
			organization: HostOrganization(
				groupPath: ["Production", "API"], tags: ["Linux", "Critical"]
			)
		)
		let staging = SSHHost(
			name: "Worker", hostname: "worker.example", username: "deploy",
			credential: .agent,
			organization: HostOrganization(
				groupPath: ["Staging"], tags: ["Linux"]
			)
		)

		let result = HostOrganizationQuery.filter(
			[production, staging],
			query: "api",
			groupPath: ["Production"],
			tag: "critical"
		)

		XCTAssertEqual(result.map(\.id), [production.id])
		XCTAssertEqual(
			HostOrganizationQuery.groups(in: [production]),
			[["Production"], ["Production", "API"]]
		)
	}

	func testBulkChangesPreserveUnrelatedOrganizationMetadata() {
		let initial = HostOrganization(
			groupPath: ["Production"], tags: ["Linux", "Critical"]
		)

		let tagged = HostOrganizationMutation.apply(
			.addTags(["On-call", "linux"]), to: initial
		)
		XCTAssertEqual(tagged.groupPath, ["Production"])
		XCTAssertEqual(tagged.tags, ["Linux", "Critical", "On-call"])

		let moved = HostOrganizationMutation.apply(
			.setGroup(["Infrastructure", "Edge"]), to: tagged
		)
		XCTAssertEqual(moved.groupPath, ["Infrastructure", "Edge"])
		XCTAssertEqual(moved.tags, tagged.tags)

		let removed = HostOrganizationMutation.apply(
			.removeTags(["CRITICAL", "missing"]), to: moved
		)
		XCTAssertEqual(removed.tags, ["Linux", "On-call"])
	}
}
