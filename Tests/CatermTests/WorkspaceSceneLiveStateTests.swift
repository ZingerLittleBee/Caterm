import AppKit
import CredentialIdentityStore
import CredentialSyncStore
import FileTransferStore
import HostSyncStore
import KeychainStore
import SessionStore
import SessionHistory
import SFTPCommandBuilder
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder
import SettingsStore
import SwiftUI
import XCTest
import WorkspaceCore
import WorkspaceTemplateStore
@testable import Caterm

@MainActor
final class WorkspaceSceneLiveStateTests: XCTestCase {
	func testSplitAndCloseCommandsImmediatelyRefreshRenderedPaneGroups() throws {
		_ = NSApplication.shared
		let fixture = try WorkspaceSceneFixture()
		defer { fixture.cleanUp() }
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		let state = WorkspaceWindowStateBox(.workspace(workspace))
		let root = fixture.sceneRoot(state: state)
		let hostingView = NSHostingView(rootView: root)
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.contentView = hostingView
		window.makeKeyAndOrderFront(nil)
		defer { window.close() }

		XCTAssertTrue(waitUntil {
			hostingView.workspacePaneGroupCount == 1
		})

		post(.splitRight, to: window)

		XCTAssertTrue(waitUntil {
			state.value.workspace?.topology.paneCount == 2
				&& hostingView.workspacePaneGroupCount == 2
		})

		post(.closePane, to: window)

		XCTAssertTrue(waitUntil {
			state.value.workspace?.topology.paneCount == 1
				&& hostingView.workspacePaneGroupCount == 1
		})
	}

	func testSavedHostBecomingAvailableRestoresSessionWithoutReopeningWindow() async throws {
		_ = NSApplication.shared
		let fixture = try WorkspaceSceneFixture()
		defer { fixture.cleanUp() }
		let host = SSHHost(
			name: "Restored Host",
			hostname: "restore.example.test",
			username: "operator",
			credential: .agent
		)
		try await fixture.sessionStore.prepareHostRepository()
		let workspace = Workspace.onePane(host: .saved(id: host.id))
		let state = WorkspaceWindowStateBox(.workspace(workspace))
		let root = fixture.sceneRoot(state: state)
		let hostingView = NSHostingView(rootView: root)
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.contentView = hostingView
		window.makeKeyAndOrderFront(nil)
		defer { window.close() }

		XCTAssertTrue(waitUntil {
			hostingView.workspacePaneGroupLabels.contains {
				$0.hasPrefix("Missing Host,")
			}
		})
		XCTAssertNil(fixture.workspaceCoordinator.sessionID(for: workspace))

		try await fixture.sessionStore.addHost(host)

		XCTAssertTrue(waitUntil(timeout: 2) {
			fixture.workspaceCoordinator.sessionID(for: workspace) != nil
		})
		XCTAssertTrue(hostingView.workspacePaneGroupLabels.contains {
			$0.hasPrefix("Restored Host,")
		})
	}

	private func post(_ command: WorkspaceCommand, to window: NSWindow) {
		NotificationCenter.default.post(
			name: .catermWorkspaceCommand,
			object: window,
			userInfo: [WorkspaceCommandNotificationKey.command: command]
		)
	}

	private func waitUntil(
		timeout: TimeInterval = 1,
		_ condition: () -> Bool
	) -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.main.run(until: Date().addingTimeInterval(0.01))
		}
		return condition()
	}
}

@MainActor
private final class WorkspaceWindowStateBox {
	var value: WorkspaceWindowState

	init(_ value: WorkspaceWindowState) {
		self.value = value
	}
}

@MainActor
private final class WorkspaceSceneFixture {
	let directory: URL
	let sessionStore: SessionStore
	let hostSyncStore: HostSyncStore
	let preferences: SyncPreferences
	let fileTransferStore: FileTransferStore
	let settingsStore: SettingsStore
	let remoteBookmarkStore: RemoteBookmarkStore
	let surfaceRegistry = SurfaceRegistry()
	let historyStore: SessionHistoryStore
	let snippetStore: SnippetStore
	let snippetSyncStore: SnippetSyncStore
	let credentialIdentityStore: CredentialIdentityStore
	let workspaceCoordinator: WorkspaceCoordinator
	let workspaceTemplateStore: WorkspaceTemplateStore
	private let defaults: UserDefaults
	private let defaultsSuiteName: String

	init() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceSceneLiveStateTests-\(UUID())")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		defaultsSuiteName = "WorkspaceSceneLiveStateTests.\(UUID())"
		guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
			throw WorkspaceSceneFixtureError.defaultsUnavailable
		}
		self.defaults = defaults
		preferences = SyncPreferences(defaults: defaults)
		preferences.periodicSyncEnabled = false
		sessionStore = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: directory.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.workspace-scene-test.\(UUID())",
				accessGroup: nil
			),
			controlMasterManager: ControlMasterManager.shared
		)
		let cloudSync = CloudSyncBootstrap.make(disabled: true)
		hostSyncStore = HostSyncStore(
			client: cloudSync.hostClient,
			sessionStore: sessionStore,
			authSession: cloudSync.accountSession,
			preferences: preferences,
			credentialSync: CredentialSyncPreferencesStore(defaults: defaults),
			masterKeyStore: KeychainSyncMasterKeyStore(),
			userDefaults: defaults
		)
		fileTransferStore = FileTransferStore { _ in
			UnavailableWorkspaceSceneRemoteFileClient()
		}
		settingsStore = SettingsStore(
			settings: .empty,
			path: directory.appendingPathComponent("settings.plist")
		)
		remoteBookmarkStore = RemoteBookmarkStore(
			directory: directory.appendingPathComponent("remote-bookmarks")
		)
		historyStore = SessionHistoryStore(
			fileURL: directory.appendingPathComponent("session-history.json")
		)
		snippetStore = SnippetStore(
			directory: directory.appendingPathComponent("snippets")
		)
		snippetSyncStore = SnippetSyncStore(
			store: snippetStore,
			client: EmptyWorkspaceSceneSnippetSyncClient()
		)
		credentialIdentityStore = CredentialIdentityStore(
			fileURL: directory.appendingPathComponent("credential-identities.json")
		)
		workspaceCoordinator = WorkspaceCoordinator(sessionStore: sessionStore)
		workspaceTemplateStore = WorkspaceTemplateStore(
			directory: directory.appendingPathComponent("templates")
		)
	}

	func sceneRoot(
		state: WorkspaceWindowStateBox
	) -> some View {
		WorkspaceSceneRoot(windowState: Binding(
			get: { state.value },
			set: { state.value = $0 }
		))
		.environmentObject(sessionStore)
		.environmentObject(hostSyncStore)
		.environmentObject(preferences)
		.environmentObject(fileTransferStore)
		.environmentObject(settingsStore)
		.environmentObject(remoteBookmarkStore)
		.environmentObject(surfaceRegistry)
		.environmentObject(historyStore)
		.environmentObject(snippetStore)
		.environmentObject(snippetSyncStore)
		.environmentObject(credentialIdentityStore)
		.environmentObject(workspaceCoordinator)
		.environmentObject(workspaceTemplateStore)
	}

	func cleanUp() {
		defaults.removePersistentDomain(forName: defaultsSuiteName)
		try? FileManager.default.removeItem(at: directory)
	}
}

private enum WorkspaceSceneFixtureError: Error {
	case defaultsUnavailable
	case unavailable
}

private struct UnavailableWorkspaceSceneRemoteFileClient: RemoteFileClient {
	func list(_ path: String) async throws -> [RemoteEntry] {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func stat(_ path: String) async throws -> RemoteEntry? {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func createDirectory(_ path: String) async throws {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func rename(from: String, to: String) async throws {
		throw WorkspaceSceneFixtureError.unavailable
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		throw WorkspaceSceneFixtureError.unavailable
	}
}

private actor EmptyWorkspaceSceneSnippetSyncClient: IncrementalSnippetSyncClient {
	func preferredSnippetSyncMode() async -> SnippetSyncMode {
		.incremental
	}

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		emptyBatch(mode: .incremental)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		emptyBatch(mode: .forceFull)
	}

	func commitSnippetCheckpoint(
		_ checkpoint: any SnippetSyncCheckpoint
	) async throws {}

	func resetSnippetSyncState() async {}

	func ensureSnippetSubscription() async throws {}

	func deleteSnippetSubscription() async throws {}

	func pushSnippet(_ snippet: Snippet) async throws -> Snippet {
		snippet
	}

	func deleteSnippet(id: UUID) async throws {}

	func hasAnySnippetSyncTokens() async -> Bool {
		false
	}

	private func emptyBatch(mode: SnippetSyncMode) -> SnippetChangeBatch {
		SnippetChangeBatch(
			changedSnippets: [],
			deletedSnippetIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: mode
		)
	}
}

private extension NSView {
	var workspacePaneGroupCount: Int {
		let current = accessibilityIdentifier().hasPrefix("workspace-pane-")
			? 1
			: 0
		return current + subviews.reduce(0) {
			$0 + $1.workspacePaneGroupCount
		}
	}

	var workspacePaneGroupLabels: [String] {
		let current = accessibilityIdentifier().hasPrefix("workspace-pane-")
			? [accessibilityLabel()].compactMap { $0 }
			: []
		return current + subviews.flatMap(\.workspacePaneGroupLabels)
	}
}
