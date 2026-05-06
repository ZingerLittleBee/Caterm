import XCTest
import ConfigStore
import SettingsStore
import SSHCommandBuilder
import KeychainStore
@testable import Caterm
@testable import SessionStore

/// Integration tests that prove the three pre-merge wiring blockers are
/// connected end-to-end. The tests exercise the seam (`BootSequence.run`,
/// `SettingsStore.changeNotification`, `SessionStore.openTab`) directly;
/// the production paths reach those same seams through `CatermApp.init`,
/// so green tests here imply the launch-path wiring is in place too.
@MainActor
final class AppBootIntegrationTests: XCTestCase {
	// MARK: - Blocker 1: BootSequence migration runs at boot

	func testBootSequenceRunsLegacyMigrationAndProducesSnapshot() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }

		// Seed legacy fingerprinted user config; settings.plist intentionally
		// missing so the load path exercises both seeding and migration.
		let userConfig = dir.appendingPathComponent("config")
		try SettingsMigrationStep.legacyDefaultV1.write(
			to: userConfig, atomically: true, encoding: .utf8
		)
		let plistURL = dir.appendingPathComponent("settings.plist")
		let snapshotURL = dir.appendingPathComponent("managed.config")
		let perHostDir = dir.appendingPathComponent("per-host")

		_ = try BootSequence.run(
			settingsPlistURL: plistURL,
			userConfigURL: userConfig,
			managedSnapshotURL: snapshotURL,
			perHostDirectory: perHostDir
		)

		// settings.plist now exists (Branch A persisted via store.save).
		XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path),
		              "BootSequence should persist settings.plist after migration")
		// User config was replaced by the placeholder banner.
		let userConfigBody = try String(contentsOf: userConfig, encoding: .utf8)
		XCTAssertEqual(userConfigBody, SettingsMigrationStep.placeholderUserConfig,
		               "Branch A should replace the legacy default with the placeholder")
		// A backup of the legacy config was written next to it.
		let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
		XCTAssertTrue(entries.contains { $0.hasPrefix("config.bak-pre-settings-gui-") },
		              "Branch A should leave a timestamped backup of the legacy config; got \(entries)")
		// Managed snapshot rendered.
		XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
		              "BootSequence should render the managed snapshot")
	}

	// MARK: - Blocker 2: SettingsStore change notification fires on flush

	func testSettingsStoreChangeNotificationCarriesScope() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let plist = dir.appendingPathComponent("settings.plist")
		let store = try SettingsStore.load(from: plist)

		let expectation = expectation(description: "change notification fires")
		// Box mutable state so the @Sendable closure can read+write across
		// MainActor.assumeIsolated. SettingsChangeScope is non-Sendable, so
		// looking it up inside an assumeIsolated block keeps things kosher.
		final class ScopeBox: @unchecked Sendable { var value: SettingsChangeScope? }
		let scope = ScopeBox()
		let scopeKey = SettingsStore.scopeUserInfoKey
		let token = NotificationCenter.default.addObserver(
			forName: SettingsStore.changeNotification,
			object: store,
			queue: .main
		) { note in
			MainActor.assumeIsolated {
				scope.value = note.userInfo?[scopeKey] as? SettingsChangeScope
			}
			expectation.fulfill()
		}
		defer { NotificationCenter.default.removeObserver(token) }

		// Mutate font-size (a `.live` field) so diff produces `.globalLive`.
		store.update { settings in
			settings.global.fontSize = (settings.global.fontSize ?? 13) + 1
		}
		store.flushNow()

		wait(for: [expectation], timeout: 1.0)
		XCTAssertEqual(scope.value, .globalLive,
		               "fontSize is a live field so flush should publish .globalLive")
	}

	func testGlobalLiveSettingsChangeReloadsActiveSurfaces() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let plist = dir.appendingPathComponent("settings.plist")
		let settingsStore = try SettingsStore.load(from: plist)
		let tabId = UUID()
		var appReloadCount = 0
		var reloadedTabs: [UUID] = []
		let coordinator = LiveReloadCoordinator(
			settingsStore: settingsStore,
			activeSurfaceTabIds: { [tabId] },
			reloadApp: { appReloadCount += 1 },
			reloadSurface: { id in reloadedTabs.append(id) },
			renderManagedSnapshot: { _ in },
			buildConfig: { [] }
		)

		settingsStore.update { settings in
			settings.global.fontSize = (settings.global.fontSize ?? 13) + 1
		}
		settingsStore.flushNow()
		_ = coordinator

		XCTAssertEqual(appReloadCount, 1)
		XCTAssertEqual(reloadedTabs, [tabId])
	}

	func testNewSurfaceOnlySettingsChangeReloadsAppWithoutReloadingSurfaces() throws {
		let dir = try makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let plist = dir.appendingPathComponent("settings.plist")
		let settingsStore = try SettingsStore.load(from: plist)
		let tabId = UUID()
		var appReloadCount = 0
		var reloadedTabs: [UUID] = []
		let coordinator = LiveReloadCoordinator(
			settingsStore: settingsStore,
			activeSurfaceTabIds: { [tabId] },
			reloadApp: { appReloadCount += 1 },
			reloadSurface: { id in reloadedTabs.append(id) },
			renderManagedSnapshot: { _ in },
			buildConfig: { [] }
		)

		settingsStore.update { settings in
			settings.global.scrollbackBytes = 50_000_000
		}
		settingsStore.flushNow()
		_ = coordinator

		XCTAssertEqual(appReloadCount, 1)
		XCTAssertEqual(reloadedTabs, [])
	}

	// MARK: - Blocker 3: openTab registers with ControlMasterManager

	func testOpenTabRegistersHostIdAndDestinationWithControlMaster() throws {
		let spy = ControlMasterIntegrationSpy()
		let store = makeSessionStore(spy: spy)
		let host = SSHHost(name: "edge",
		                   hostname: "10.0.0.5",
		                   port: 22,
		                   username: "ops",
		                   credential: .password)

		_ = store.openTab(host: host)

		XCTAssertEqual(spy.registered.count, 1,
		               "openTab should register exactly once")
		XCTAssertEqual(spy.registered.first?.hostId, host.id)
		XCTAssertEqual(spy.registered.first?.destination, "ops@10.0.0.5")
	}

	// MARK: - Helpers

	private func makeTempDir() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("AppBootIntegrationTests-\(UUID())")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func makeSessionStore(spy: ControlMasterIntegrationSpy) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("AppBootIntegrationTests-hosts-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		return SessionStore(askpassPath: "/dev/null",
		                    knownHostsCaterm: "/dev/null",
		                    knownHostsUser: "/dev/null",
		                    accessGroup: nil,
		                    hostsURL: tmp,
		                    keychain: kc,
		                    controlMasterManager: spy)
	}
}

/// Spy that records `register` calls in addition to teardown. Lives at file
/// scope so the test methods can assert against `registered`.
private final class ControlMasterIntegrationSpy: ControlMasterTearDowning, @unchecked Sendable {
	struct Registration: Equatable {
		let hostId: UUID
		let destination: String
	}
	var registered: [Registration] = []
	var torn: [UUID] = []
	var allCount = 0

	func register(hostId: UUID, destination: String) {
		registered.append(Registration(hostId: hostId, destination: destination))
	}

	func tearDown(hostId: UUID) async {
		torn.append(hostId)
	}

	func tearDownAll() async {
		allCount += 1
	}
}
