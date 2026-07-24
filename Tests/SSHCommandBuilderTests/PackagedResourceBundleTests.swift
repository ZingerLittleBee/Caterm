import Foundation
import Testing
@testable import SSHCommandBuilder

@Suite("Packaged terminfo resources")
struct PackagedTerminfoResourceTests {
	@Test("Finds the SwiftPM bundle inside macOS app resources")
	func findsBundleInMacAppResources() throws {
		let fixture = try MacAppResourceFixture(
			bundleName: "Caterm_SSHCommandBuilder.bundle",
			resourceName: "xterm-ghostty.terminfo"
		)
		defer { fixture.cleanup() }

		let mainBundle = try #require(Bundle(url: fixture.appURL))
		let resourceBundle = try #require(
			TerminfoSource.packagedResourceBundle(in: mainBundle)
		)
		let resourceURL = try #require(
			resourceBundle.url(
				forResource: "xterm-ghostty",
				withExtension: "terminfo"
			)
		)

		#expect(resourceURL.standardizedFileURL == fixture.resourceURL.standardizedFileURL)
	}
}

private struct MacAppResourceFixture {
	let root: URL
	let appURL: URL
	let resourceURL: URL

	init(bundleName: String, resourceName: String) throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mac-resource-\(UUID().uuidString)")
		appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
		let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
		let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
		let bundleURL = resourcesURL.appendingPathComponent(bundleName, isDirectory: true)
		resourceURL = bundleURL.appendingPathComponent(resourceName)

		try FileManager.default.createDirectory(
			at: bundleURL,
			withIntermediateDirectories: true
		)
		try "fixture".write(to: resourceURL, atomically: true, encoding: .utf8)
		let plist: [String: Any] = [
			"CFBundleIdentifier": "app.caterm.resource-fixture",
			"CFBundleName": "Fixture",
			"CFBundlePackageType": "APPL",
			"CFBundleVersion": "1",
		]
		let plistData = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .xml,
			options: 0
		)
		try plistData.write(
			to: contentsURL.appendingPathComponent("Info.plist")
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: root)
	}
}
