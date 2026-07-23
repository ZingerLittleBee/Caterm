import Foundation
import Testing
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@Suite("ControlMaster path integration")
@MainActor
struct ControlMasterPathTests {
	private final class ImmediatePreflight: PreflightProbing, @unchecked Sendable {
		func probe(
			host _: String,
			port _: UInt16,
			timeout _: TimeInterval
		) async -> PreflightOutcome {
			.ok
		}

		func probeLocalBind(
			address _: String,
			port _: UInt16
		) async -> PortBindOutcome {
			.available
		}
	}

	@MainActor
	private final class PathManager: ControlMasterManaging {
		let directory: URL

		init(directory: URL) {
			self.directory = directory
		}

		func socketPath(for hostId: UUID) -> URL {
			directory.appendingPathComponent("\(hostId.uuidString).sock")
		}

		func register(hostId _: UUID, destination _: String) {}
		func tearDown(hostId _: UUID) async {}
		func tearDownAll() async {}
	}

	@Test("Connection command uses the manager's exact socket path")
	func connectionCommandUsesManagerSocketPath() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm isolated home", isDirectory: true)
		let manager = PathManager(directory: root)
		let host = SSHHost(
			name: "Fixture",
			hostname: "127.0.0.1",
			port: 2225,
			username: "caterm",
			credential: .agent
		)
		let store = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.test.\(UUID().uuidString)",
				accessGroup: nil
			),
			controlMasterManager: manager,
			preflight: ImmediatePreflight()
		)

		let tabID = store.openTab(host: host)
		await store.awaitConnectionAttempt(tabId: tabID)

		let config = try #require(store.surfaceConfig(for: tabID))
		let expectedPath = manager.socketPath(for: host.id).path
		#expect(config.command.contains("ControlPath=\"\(expectedPath)\""))
		#expect(!config.command.contains("~/Library/Caches/Caterm/cm/"))
	}
}
