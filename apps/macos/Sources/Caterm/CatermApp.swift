import AppKit
import CloudKit
import CloudKitSyncClient
import ConfigStore
import CredentialSync
import CredentialSyncStore
import FileTransferStore
import Foundation
import HostSyncStore
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SettingsSyncStore
import SFTPCommandBuilder
import SSHCommandBuilder
import SwiftUI
import TerminalEngine

@main
struct CatermApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
	@StateObject var store: SessionStore
	@StateObject var syncStore: HostSyncStore
	@StateObject var preferences: SyncPreferences
	@StateObject var fileTransferStore: FileTransferStore
	@StateObject var settingsStore: SettingsStore
	@StateObject var remoteBookmarks: RemoteBookmarkStore
	@StateObject private var credentialSync: CredentialSyncPreferencesStore
	@StateObject var surfaceRegistry: SurfaceRegistry = SurfaceRegistry()
	@StateObject private var snippetStore: SnippetStore
	@StateObject private var snippetSync: SnippetSyncStore

	/// Holds the live-reload dispatcher and its NotificationCenter
	/// observer for the app's lifetime. See `LiveReloadCoordinator`.
	let liveReload: LiveReloadCoordinator

	let cloudKitClient: CloudKitSyncClient
	let icloudSession: iCloudAccountSession
	private let accountIdentityTracker: AccountIdentityTracker
	private let settingsSync: SettingsSyncStore
	private let masterKeyStore: KeychainSyncMasterKeyStore
	private let managedKeyStore: ManagedKeyStore
	private let credentialSyncCoordinator: CredentialSyncCoordinator
	private let credentialSyncAccountReset: CredentialSyncAccountResetCoordinator

	init() {
		try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
		let session = makeStore()
		// CloudKit-backed sync (the URLSession + better-auth pair was removed
		// in Plan E). `iCloudAccountSession` is the AuthSessionProtocol
		// conformer threaded into HostSyncStore.
		let cloudContainer = CKContainer(identifier: "iCloud.com.caterm.app")
		let icloudSession = iCloudAccountSession(provider: cloudContainer)
		self.icloudSession = icloudSession
		let client = CloudKitSyncClient(database: cloudContainer.privateCloudDatabase)
		self.cloudKitClient = client
		self.accountIdentityTracker = AccountIdentityTracker(
			currentUserRecordID: { try? await cloudContainer.userRecordID() },
			tokensExist: { await client.hasAnyHostSyncTokens() }
		)
		let prefs = SyncPreferences()
		// Single instances shared across HostSyncStore + Coordinator + UI so
		// toggle/reset state stays consistent.
		let credentialSyncPrefs = CredentialSyncPreferencesStore()
		let mks = KeychainSyncMasterKeyStore()
		let mngs = ManagedKeyStore()
		self.masterKeyStore = mks
		self.managedKeyStore = mngs
		self.credentialSyncCoordinator = CredentialSyncCoordinator(
			prefsStore: credentialSyncPrefs,
			masterKeyStore: mks,
			iCloudKeychainAvailable: { true }
		)
		self.credentialSyncAccountReset = CredentialSyncAccountResetCoordinator(
			prefsStore: credentialSyncPrefs,
			managedKeyStore: mngs
		)
		_credentialSync = StateObject(wrappedValue: credentialSyncPrefs)
		// `_store = StateObject(wrappedValue:)` is the underscore-prefixed
		// property-wrapper init — required because `@StateObject` cannot be
		// assigned via the synthesized `self.store = ...` syntax in `init`.
		_store = StateObject(wrappedValue: session)
		_preferences = StateObject(wrappedValue: prefs)
		_syncStore = StateObject(wrappedValue: HostSyncStore(
			client: client,
			sessionStore: session,
			authSession: icloudSession,
			preferences: prefs,
			credentialSync: credentialSyncPrefs,
			masterKeyStore: mks,
			managedKeyStore: mngs
		))
		// Refresh CloudKit account status asynchronously. HostSyncStore.syncIfSignedIn
		// (called from .task in body) handles the case where refresh hasn't completed
		// yet — it sees isSignedIn=false and skips; the .CKAccountChanged observer
		// re-triggers sync once the status flips.
		Task { @MainActor in
			await icloudSession.refresh()
			NotificationCenter.default.post(
				name: .catermICloudAccountChanged, object: nil
			)
		}
		icloudSession.startObservingAccountChanges()
		// Per-app FileTransferStore. Closures capture plain value types
		// (URLs / paths) rather than `ControlMasterManager` itself so the
		// closure body remains nonisolated-callable. Liveness goes through
		// `ControlMasterManager.shared`'s async `isAlive(hostId:)`, which
		// crosses isolation properly.
		let cmDir = (try? CacheDirectories.controlMasterDir())
			?? URL(fileURLWithPath: NSTemporaryDirectory())
		let askpass = URL(fileURLWithPath: session.askpassPath)
		let knownCaterm = URL(fileURLWithPath: session.knownHostsCaterm)
		let knownUser = URL(fileURLWithPath: session.knownHostsUser)
		// SettingsStore: loaded eagerly through `BootSequence.run` so the
		// legacy → plist migration (Branch A/B/C), managed-snapshot render,
		// and per-host patch regeneration all run on launch. Per-host theme
		// overrides (Task 24) and the Preferences window (Task 25) share
		// this observable instance. If BootSequence throws (disk fault,
		// permissions issue, etc.), fall back to a defaults-seeded
		// in-memory store so the app still launches — same shape as
		// `PreferencesWindowController`'s fallback.
		let plistPath = SettingsStore.defaultPlistPath
		let settings: SettingsStore
		do {
			settings = try BootSequence.run(
				settingsPlistURL: plistPath,
				userConfigURL: ConfigStore.defaultPath,
				managedSnapshotURL: ConfigStore.managedConfigPath,
				perHostDirectory: ConfigStore.perHostPatchDirectory
			)
		} catch {
			NSLog("[CatermApp] BootSequence failed, using in-memory defaults: \(error)")
			settings = SettingsStore(
				settings: CatermSettings(global: CatermSettings.defaultsSeed),
				path: plistPath
			)
		}
		_settingsStore = StateObject(wrappedValue: settings)
		// Per-host remote-path bookmarks (SFTP file drawer). Lives next to
		// hosts.json under Application Support/Caterm/RemoteBookmarks/<hostId>.json.
		let bookmarksDir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
			.appendingPathComponent("RemoteBookmarks", isDirectory: true)
		_remoteBookmarks = StateObject(wrappedValue: RemoteBookmarkStore(directory: bookmarksDir))
		// Snippet store: JSON files under Application Support/Caterm/Snippets/.
		// Loaded eagerly so the palette and editor have data on first launch.
		let snippetsDir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
		let snippetStoreInstance = SnippetStore(directory: snippetsDir)
		try? snippetStoreInstance.load()
		_snippetStore = StateObject(wrappedValue: snippetStoreInstance)
		let snippetSyncInstance = SnippetSyncStore(store: snippetStoreInstance, client: client)
		_snippetSync = StateObject(wrappedValue: snippetSyncInstance)
		_fileTransferStore = StateObject(wrappedValue: FileTransferStore(
			controlPathFor: { hostId in
				cmDir.appendingPathComponent("\(hostId.uuidString).sock")
			},
			credentialsFor: { _ in
				SFTPCredentials(
					askpassPath: askpass,
					identityFiles: [],
					knownHostsCaterm: knownCaterm,
					knownHostsUser: knownUser,
					strictHostKeyChecking: .acceptNew
				)
			},
			liveness: ControlMasterManager.shared
		))
		// Wire the live-reload pipeline. `LiveReloadDispatcher` already
		// posts `catermNewSurfaceBanner` / `catermConfigDiagnostics`
		// notifications internally — `SettingsBannerState` listens to
		// both — so banner + managed-snapshot rerender works today.
		// Per-surface live application of font/theme/cursor onto
		// already-mounted Ghostty surfaces is deferred (no surface
		// registry yet); new surfaces still pick up changes via the
		// next render of the managed snapshot.
		self.liveReload = LiveReloadCoordinator(settingsStore: settings)
		let tokenStore = IdentityTokenStore()
		let kvsAdapter: KVSProtocol = NSUbiquitousKeyValueStore.default
		self.settingsSync = SettingsSyncStore(
			store: settings,
			kvs: kvsAdapter,
			accountSession: icloudSession,
			tokenStore: tokenStore,
			currentTokenProvider: { FileManager.default.ubiquityIdentityToken as? (NSObject & NSCoding & NSCopying) }
		)
		self.settingsSync.installLifecycleObservers()
		Task { @MainActor [settingsSync = self.settingsSync] in
			await settingsSync.startSync()
		}
	}

	var body: some Scene {
		// Each tab in the OS-provided native tab bar is one window in this
		// `WindowGroup(for: UUID.self)`. macOS auto-tabs them because
		// `NSWindow.allowsAutomaticWindowTabbing = true` (AppDelegate).
		//
		// When `tabId == nil` the user opened a "fresh" window via the
		// File > New Window default; show the landing screen with the host
		// list sidebar.
		WindowGroup(for: UUID.self) { $tabId in
			Group {
				if let id = tabId, store.tabs.contains(where: { $0.id == id }) {
					MainWindow(tabId: id)
				} else {
					// Pass the tabId binding so connecting from this Landing
					// window converts it into the new tab in place instead of
					// spawning a sibling blank tab.
					LandingView(tabId: $tabId)
				}
			}
			.environmentObject(store)
			.environmentObject(syncStore)        // NEW (v1.4)
			.environmentObject(preferences)      // NEW (v1.4)
			.environmentObject(fileTransferStore)
			.environmentObject(settingsStore)
			.environmentObject(remoteBookmarks)
			.environmentObject(surfaceRegistry)
			.environmentObject(snippetStore)
			.environmentObject(snippetSync)
			.background(OpenTabBridge(store: store))
			// .task closure is sync — syncIfSignedIn() returns immediately;
			// the actual sync work runs as an unstructured Task owned by
			// HostSyncStore.inFlight (NOT by this .task modifier). View
			// disappearance does not cancel the sync — that's intentional;
			// cancellation lives in the chain (spec §3.5).
			.task { syncStore.syncIfSignedIn() }
			.task {
				try? await cloudKitClient.ensureHostSubscription()
			}
			.task {
				snippetSync.scheduleSyncPass(mode: .incremental)
			}
			.task {
				try? await cloudKitClient.ensureSnippetSubscription()
			}
			.onReceive(NotificationCenter.default
				.publisher(for: .catermCloudKitSnippetChanged)) { _ in
				snippetSync.scheduleSyncPass(mode: .incremental)
			}
			.onReceive(NotificationCenter.default
				.publisher(for: .catermICloudAccountChanged)) { _ in
				syncStore.syncIfSignedIn()
			}
			.onReceive(NotificationCenter.default
				.publisher(for: .catermICloudAccountChanged)) { _ in
				Task {
					let outcome = await accountIdentityTracker.handleAccountChange(client: cloudKitClient)
					if outcome == .identityChanged {
						await credentialSyncAccountReset.resetForAccountChange()
						try? snippetStore.wipeLocal()
						snippetSync.scheduleSyncPass(mode: .forceFull)
					}
				}
			}
			.onReceive(NotificationCenter.default
				.publisher(for: .catermOpenSyncSettings)) { _ in
				// Sync settings now live as a tab inside the Preferences
				// window (Task 25). SyncStatusRow still posts this
				// notification when the user clicks the indicator; route
				// it through to the unified Preferences surface.
				PreferencesWindowController.shared.syncEnvironment = SyncEnvironment(
					authSession: icloudSession,
					syncStore: syncStore,
					preferences: preferences,
					credentialSync: credentialSync,
					credentialSyncCoordinator: credentialSyncCoordinator,
					sessionStore: store
				)
				PreferencesWindowController.shared.activate(tabIndex: 3)
				PreferencesWindowController.shared.showAndActivate()
			}
		}
		.commands {
			// ⌘N opens a fresh LandingView window (OpenTabBridge handles the
			// notification by calling openWindow(value: UUID())).
			// ⌘T adds a new host (the sidebar listens and opens its add-sheet).
			CommandGroup(replacing: .newItem) {
				Button("New Window") {
					NotificationCenter.default.post(name: .catermNewWindow, object: nil)
				}
				.keyboardShortcut("n", modifiers: .command)
				Button("New Host…") {
					NotificationCenter.default.post(name: .catermAddHost, object: nil)
				}
				.keyboardShortcut("t", modifiers: .command)
			}
			// ⌘, opens the unified Preferences window (Task 25).
			// "Edit Advanced Config…" inside General still reveals the TOML
			// config in Finder for power users, so no functionality is lost.
			CommandGroup(replacing: .appSettings) {
				Button("Settings…") {
					PreferencesWindowController.shared.syncEnvironment = SyncEnvironment(
						authSession: icloudSession,
						syncStore: syncStore,
						preferences: preferences,
						credentialSync: credentialSync,
						credentialSyncCoordinator: credentialSyncCoordinator,
						sessionStore: store
					)
					PreferencesWindowController.shared.showAndActivate()
				}
				.keyboardShortcut(",", modifiers: .command)
			}
			// Edit menu pasteboard commands. Selectors are the standard
			// `NSText.copy/paste/pasteAsPlainText`, which AppKit
			// responder-chain-dispatches; whichever view is first responder
			// (e.g. GhosttySurfaceNSView) handles them.
			CommandGroup(replacing: .pasteboard) {
				Button("Copy") {
					NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("c", modifiers: [.command])

				Button("Paste") {
					NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("v", modifiers: [.command])

				Button("Paste and Match Style") {
					NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("v", modifiers: [.command, .option, .shift])
			}
			// ⌘B toggles the host-list sidebar. NavigationSplitView
			// installs an `NSSplitViewController` in the responder chain
			// that handles `toggleSidebar:`. Use `NSApp.sendAction(_:to:
			// from:)` with `to: nil` so AppKit walks the responder chain
			// from the key window — `firstResponder?.tryToPerform(...)`
			// alone misses the split-view controller because the chain
			// starts a few links above first responder.
			CommandGroup(after: .sidebar) {
				Button("Toggle Sidebar") {
					NSApp.sendAction(
						#selector(NSSplitViewController.toggleSidebar(_:)),
						to: nil,
						from: nil
					)
				}
				.keyboardShortcut("b", modifiers: .command)
			}
			// ⌘⇧F toggles the per-window Files drawer. The notification is
			// observed by `MainWindow`; broadcasting via NotificationCenter
			// avoids threading window-local @State through App scene.
			CommandGroup(after: .toolbar) {
				Button("Toggle Files Drawer") {
					NotificationCenter.default.post(name: .toggleFileDrawer, object: nil)
				}
				.keyboardShortcut("f", modifiers: [.command, .shift])
			}
			// Snippet commands: palette (⌘⇧P), new snippet (⌘⇧S), manager.
			// These post notifications that `SnippetCommandObserver` picks up
			// in the key window only, avoiding multi-window broadcast.
			CommandGroup(after: .toolbar) {
				Button("Open Snippet Palette") {
					NotificationCenter.default.post(name: .catermOpenSnippetPalette, object: nil)
				}
				.keyboardShortcut("p", modifiers: [.command, .shift])

				Button("New Snippet…") {
					NotificationCenter.default.post(name: .catermNewSnippet, object: nil)
				}
				.keyboardShortcut("s", modifiers: [.command, .shift])

				Button("Manage Snippets…") {
					NotificationCenter.default.post(name: .catermOpenSnippetManager, object: nil)
				}
			}
			// Help menu → GitHub documentation page.
			CommandGroup(replacing: .help) {
				Link("Caterm Documentation",
				     destination: URL(string: "https://github.com/ZingerLittleBee/Caterm")!)
			}
		}
	}
}

extension Notification.Name {
	static let catermAddHost = Notification.Name("CatermAddHostNotification")
	static let catermNewWindow = Notification.Name("CatermNewWindowNotification")
}

/// Invisible bridge view that lets us call `openWindow(value:)` (which needs
/// `@Environment(\.openWindow)` from inside a SwiftUI View) in response to
/// the `.catermNewWindow` notification (⌘N).
///
/// Tab opening from the host list is NOT routed through here — it goes
/// through `HostListSidebar.onOpenTab`, so the owning window can decide
/// whether to swap its own tab identity (Landing case) or spawn a sibling
/// (MainWindow case). Routing it through a global notification used to
/// always spawn a sibling, which left the Landing window around as a blank
/// tab next to the new SSH terminal tab.
struct OpenTabBridge: View {
	@Environment(\.openWindow) var openWindow
	let store: SessionStore

	var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.onReceive(NotificationCenter.default.publisher(for: .catermNewWindow)) { _ in
				// A fresh UUID that is not in store.tabs causes WindowGroup to
				// render LandingView rather than MainWindow — effectively a new
				// blank window in the tab bar.
				openWindow(value: UUID())
			}
	}
}

/// Initial landing view shown when a "fresh" (tabId-less) window opens.
/// Embeds the host list sidebar so users can manage hosts before any tab
/// is open. When the user picks a host, swap our own `tabId` binding to
/// the new tab id — this morphs the current window from Landing into
/// MainWindow rather than spawning a separate window/tab.
struct LandingView: View {
	@Binding var tabId: UUID?
	@EnvironmentObject var snippetStore: SnippetStore
	@EnvironmentObject var snippetSync: SnippetSyncStore
	@State private var presentingPalette = false
	@State private var presentingEditor = false
	@State private var presentingManager = false
	@State private var hostWindow: NSWindow?

	var body: some View {
		NavigationSplitView {
			HostListSidebar(onOpenTab: { newId in tabId = newId })
				.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
		} detail: {
			VStack(spacing: 12) {
				Image(systemName: "terminal").font(.system(size: 64))
					.foregroundColor(.secondary)
				Text("Caterm").font(.largeTitle)
				Text("Pick a host from the sidebar, or press ⌘T to add one")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(minWidth: 1000, minHeight: 600)
		.background(WindowAccessor(window: $hostWindow))
		.modifier(SnippetCommandObserver(
			presentingPalette: $presentingPalette,
			presentingEditor: $presentingEditor,
			presentingManager: $presentingManager,
			isKeyWindow: { hostWindow?.isKeyWindow ?? false }
		))
		.popover(isPresented: $presentingPalette) {
			SnippetPalette(
				store: snippetStore,
				capturedSurface: nil,
				onClose: { presentingPalette = false },
				onCreate: { presentingPalette = false; presentingEditor = true }
			)
		}
		.sheet(isPresented: $presentingEditor) {
			SnippetEditorSheet(mode: .create)
				.environmentObject(snippetStore)
				.environmentObject(snippetSync)
		}
		.sheet(isPresented: $presentingManager) {
			SnippetManagerSheet()
				.environmentObject(snippetStore)
				.environmentObject(snippetSync)
		}
	}
}

@MainActor
private func makeStore() -> SessionStore {
	let supportDir = FileManager.default
		.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		.appendingPathComponent("Caterm", isDirectory: true)
	try? FileManager.default.createDirectory(at: supportDir,
	                                         withIntermediateDirectories: true)
	let knownCaterm = supportDir.appendingPathComponent("known_hosts").path
	let knownUser = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath
	let hostsURL = supportDir.appendingPathComponent("hosts.json")

	// Dev: askpass binary path can be overridden via env. In a packaged .app
	// it would sit alongside the main binary in Contents/MacOS/.
	// For a SwiftPM CLI executable, `Bundle.main.executableURL` is the binary
	// itself; its parent directory contains the sibling `caterm-askpass`.
	let askpassPath = ProcessInfo.processInfo.environment["CATERM_DEV_ASKPASS_PATH"]
		?? Bundle.main.executableURL!
		.deletingLastPathComponent()
		.appendingPathComponent("caterm-askpass").path

	// Task 1.3 finding: AMFI rejects keychain-access-groups on dev signing.
	// In dev path we leave accessGroup nil and fall back to the login keychain.
	let teamId = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
	let accessGroup = teamId.isEmpty ? nil : "\(teamId).caterm.shared"

	let keychain = KeychainStore(service: "com.caterm.host", accessGroup: accessGroup)

	return SessionStore(askpassPath: askpassPath,
	                    knownHostsCaterm: knownCaterm,
	                    knownHostsUser: knownUser,
	                    accessGroup: accessGroup,
	                    hostsURL: hostsURL,
	                    keychain: keychain,
	                    controlMasterManager: ControlMasterManager.shared)
}
