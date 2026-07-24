import Foundation
import Testing

@Suite("SwiftPM resource embedding script")
struct SwiftPMResourceEmbeddingScriptTests {
	@Test("Copies every resource bundle and preserves its contents")
	func copiesAllResourceBundles() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		try fixture.write("terminfo", to: "Caterm_SSHCommandBuilder.bundle/xterm-ghostty.terminfo")
		try fixture.write("themes", to: "Caterm_SettingsStore.bundle/themes.json")
		try fixture.write("shader", to: "SwiftTerm_SwiftTerm.bundle/Shaders.metal")
		try fixture.write("ignore", to: "caterm")

		let result = try fixture.run()

		#expect(result.status == 0, Comment(rawValue: result.output))
		#expect(
			try fixture.embeddedContents(
				at: "Caterm_SSHCommandBuilder.bundle/xterm-ghostty.terminfo"
			) == "terminfo"
		)
		#expect(
			try fixture.embeddedContents(
				at: "Caterm_SettingsStore.bundle/themes.json"
			) == "themes"
		)
		#expect(
			try fixture.embeddedContents(
				at: "SwiftTerm_SwiftTerm.bundle/Shaders.metal"
			) == "shader"
		)
		#expect(!fixture.embeddedFileExists(at: "caterm"))
	}

	@Test("Fails when SwiftPM produced no resource bundles")
	func rejectsMissingResourceBundles() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }

		let result = try fixture.run()

		#expect(result.status != 0)
		#expect(result.output.contains("no SwiftPM resource bundles found"))
	}
}

private struct Fixture {
	let root: URL
	let buildDirectory: URL
	let destinationDirectory: URL

	init() throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-resource-embedding-\(UUID().uuidString)")
		buildDirectory = root.appendingPathComponent("build", isDirectory: true)
		destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
		try FileManager.default.createDirectory(
			at: buildDirectory,
			withIntermediateDirectories: true
		)
	}

	func write(_ contents: String, to relativePath: String) throws {
		let url = buildDirectory.appendingPathComponent(relativePath)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try contents.write(to: url, atomically: true, encoding: .utf8)
	}

	func run() throws -> (status: Int32, output: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [
			"Scripts/embed-swiftpm-resources.sh",
			buildDirectory.path,
			destinationDirectory.path,
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
		return (process.terminationStatus, output)
	}

	func embeddedContents(at relativePath: String) throws -> String {
		try String(
			contentsOf: destinationDirectory.appendingPathComponent(relativePath),
			encoding: .utf8
		)
	}

	func embeddedFileExists(at relativePath: String) -> Bool {
		FileManager.default.fileExists(
			atPath: destinationDirectory.appendingPathComponent(relativePath).path
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: root)
	}
}
