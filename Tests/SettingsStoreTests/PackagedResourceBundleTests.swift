import Foundation
import Testing
@testable import SettingsStore

@Suite("Packaged theme resources")
struct PackagedThemeResourceTests {
	@Test("Finds the SwiftPM bundle inside macOS app resources")
	func findsBundleInMacAppResources() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-theme-resource-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
		let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
		let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
		let bundleURL = resourcesURL.appendingPathComponent(
			"Caterm_SettingsStore.bundle",
			isDirectory: true
		)
		let themesURL = bundleURL.appendingPathComponent("themes.json")

		try FileManager.default.createDirectory(
			at: bundleURL,
			withIntermediateDirectories: true
		)
		try "[]".write(to: themesURL, atomically: true, encoding: .utf8)
		let plist: [String: Any] = [
			"CFBundleIdentifier": "app.caterm.theme-resource-fixture",
			"CFBundleName": "Fixture",
			"CFBundlePackageType": "APPL",
			"CFBundleVersion": "1",
		]
		let plistData = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .xml,
			options: 0
		)
		try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

		let mainBundle = try #require(Bundle(url: appURL))
		let resourceBundle = try #require(
			ThemeCatalog.packagedResourceBundle(in: mainBundle)
		)
		let resourceURL = try #require(
			resourceBundle.url(forResource: "themes", withExtension: "json")
		)

		#expect(resourceURL.standardizedFileURL == themesURL.standardizedFileURL)
	}
}
