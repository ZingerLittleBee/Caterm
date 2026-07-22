import Foundation
import XCTest

final class IOSSigningEntitlementsScriptTests: XCTestCase {
	private let teamID = "TEAM123456"
	private let bundleID = "app.caterm.mobile"

	func testDevelopmentProfileResolvesDevelopmentEnvironments() throws {
		let result = try runResolver(
			apsEnvironment: "development",
			cloudKitEnvironment: "Development"
		)

		XCTAssertEqual(result.status, 0, result.output)
		let entitlements = try readPlist(result.outputURL)
		XCTAssertEqual(entitlements["aps-environment"] as? String, "development")
		XCTAssertEqual(
			entitlements["com.apple.developer.team-identifier"] as? String,
			teamID
		)
		XCTAssertEqual(
			entitlements["com.apple.developer.icloud-container-environment"] as? String,
			"Development"
		)
	}

	func testProductionProfileResolvesProductionEnvironments() throws {
		let result = try runResolver(
			apsEnvironment: "production",
			cloudKitEnvironment: "Production"
		)

		XCTAssertEqual(result.status, 0, result.output)
		let entitlements = try readPlist(result.outputURL)
		XCTAssertEqual(entitlements["aps-environment"] as? String, "production")
		XCTAssertEqual(
			entitlements["com.apple.developer.team-identifier"] as? String,
			teamID
		)
		XCTAssertEqual(
			entitlements["com.apple.developer.icloud-container-environment"] as? String,
			"Production"
		)
	}

	func testMismatchedApplicationIdentifierIsRejected() throws {
		let result = try runResolver(
			apsEnvironment: "production",
			cloudKitEnvironment: "Production",
			applicationIdentifier: "OTHER.app.caterm.mobile"
		)

		XCTAssertNotEqual(result.status, 0)
		XCTAssertTrue(result.output.contains("application-identifier mismatch"))
	}

	private func runResolver(
		apsEnvironment: String,
		cloudKitEnvironment: String,
		applicationIdentifier: String? = nil
	) throws -> (status: Int32, output: String, outputURL: URL) {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("ios-entitlements-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: true
		)
		addTeardownBlock { try? FileManager.default.removeItem(at: root) }
		let profileURL = root.appendingPathComponent("profile.plist")
		let outputURL = root.appendingPathComponent("resolved.plist")
		let expectedAppID = "\(teamID).\(bundleID)"
		let profile: [String: Any] = [
			"Entitlements": [
				"application-identifier": applicationIdentifier ?? expectedAppID,
				"com.apple.developer.team-identifier": teamID,
				"com.apple.developer.ubiquity-kvstore-identifier": expectedAppID,
				"keychain-access-groups": ["\(teamID).caterm.shared"],
				"com.apple.developer.icloud-container-identifiers": [
					"iCloud.com.caterm.app"
				],
				"com.apple.developer.icloud-services": ["CloudKit"],
				"com.apple.developer.icloud-container-environment": cloudKitEnvironment,
				"aps-environment": apsEnvironment,
			],
		]
		let data = try PropertyListSerialization.data(
			fromPropertyList: profile,
			format: .xml,
			options: 0
		)
		try data.write(to: profileURL)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [
			"Scripts/resolve-ios-entitlements.sh",
			profileURL.path,
			"Resources/CatermMobile.entitlements",
			outputURL.path,
			teamID,
			bundleID,
		]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		process.waitUntilExit()
		let output = String(
			data: pipe.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""
		return (process.terminationStatus, output, outputURL)
	}

	private func readPlist(_ url: URL) throws -> [String: Any] {
		let data = try Data(contentsOf: url)
		return try XCTUnwrap(
			PropertyListSerialization.propertyList(
				from: data,
				options: [],
				format: nil
			) as? [String: Any]
		)
	}
}
