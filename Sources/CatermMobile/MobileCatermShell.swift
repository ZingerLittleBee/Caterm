import CatermMobileTerminal
import Combine
import FileTransferStore
import SnippetSyncClient
import SnippetStore
import SSHCommandBuilder
import SettingsStore
import SettingsSyncStore
import SwiftUI

/// Array-seeded mobile shell. Keeps an in-memory `@State` copy of every
/// surface — used by previews and tests. The running iOS app uses
/// `MobileRootView`, which is backed by real persisting stores.
public struct MobileCatermShell: View {
	@State private var hosts: [SSHHost]
	@State private var snippets: [Snippet]
	@State private var remoteEntries: [RemoteEntry]
	@State private var transfers: [TransferTask]

	public init(
		hosts: [SSHHost] = [],
		snippets: [Snippet] = [],
		remoteEntries: [RemoteEntry] = [],
		transfers: [TransferTask] = []
	) {
		_hosts = State(initialValue: hosts)
		_snippets = State(initialValue: snippets)
		_remoteEntries = State(initialValue: remoteEntries)
		_transfers = State(initialValue: transfers)
	}

	public var body: some View {
		MobileShellBody(
			hosts: $hosts,
			snippets: $snippets,
			remoteEntries: $remoteEntries,
			transfers: $transfers,
			settingsStore: nil,
			terminalPreferences: .storedDefaults,
			remoteFileClientFactory: .unavailable,
			fileTransferStore: nil,
			transferWorkspace: nil
		)
	}
}

/// The real iOS/iPadOS app entry. Owns persisting stores and feeds the
/// shared shell body store-backed bindings, so host edits round-trip to
/// the same on-disk JSON the macOS app and CloudKit sync use. AppKit and
/// the desktop terminal surface stay isolated.
public struct MobileRootView: View {
	@StateObject private var hostStore: MobileHostStore
	@StateObject private var snippetStore: SnippetStore
	@StateObject private var snippetSyncRuntime: MobileSnippetSyncRuntime
	@StateObject private var settingsStore: SettingsStore
	@StateObject private var syncCoordinator: MobileSyncCoordinator
	@Environment(\.scenePhase) private var scenePhase
	private let hostSaveCoordinator: MobileHostSaveCoordinator
	private let backupImportCoordinator: MobileBackupImportCoordinator
	private let terminalSessionFactory: MobileTerminalSessionFactory
	private let remoteFileClientFactory: MobileRemoteFileClientFactory
	private let fileTransferStore: FileTransferStore
	private let transferWorkspace: MobileTransferWorkspace
	@State private var operationError: MobileHostOperationError?
	@State private var remoteEntries: [RemoteEntry]
	@State private var transfers: [TransferTask]

	public init(
		hostStore: MobileHostStore,
		credentialWriter: MobileCredentialWriter,
		snippetStore: SnippetStore,
		snippetSyncRuntime: MobileSnippetSyncRuntime,
		settingsStore: SettingsStore,
		syncCoordinator: MobileSyncCoordinator,
		terminalSessionFactory: MobileTerminalSessionFactory,
		remoteFileClientFactory: MobileRemoteFileClientFactory,
		fileTransferStore: FileTransferStore,
		transferWorkspace: MobileTransferWorkspace,
		prepareCredentialSyncForSave: @escaping MobileCredentialSyncPreparation = { _ in },
		remoteEntries: [RemoteEntry] = [],
		transfers: [TransferTask] = []
	) {
		_hostStore = StateObject(wrappedValue: hostStore)
		_snippetStore = StateObject(wrappedValue: snippetStore)
		_snippetSyncRuntime = StateObject(wrappedValue: snippetSyncRuntime)
		_settingsStore = StateObject(wrappedValue: settingsStore)
		_syncCoordinator = StateObject(wrappedValue: syncCoordinator)
		self.hostSaveCoordinator = MobileHostSaveCoordinator(
			hostStore: hostStore,
			credentialWriter: credentialWriter,
			prepareCredentialSyncForSave: prepareCredentialSyncForSave
		)
		self.backupImportCoordinator = MobileBackupImportCoordinator(
			hostStore: hostStore
		)
		self.terminalSessionFactory = terminalSessionFactory
		self.remoteFileClientFactory = remoteFileClientFactory
		self.fileTransferStore = fileTransferStore
		self.transferWorkspace = transferWorkspace
		_remoteEntries = State(initialValue: remoteEntries)
		_transfers = State(initialValue: transfers)
	}

	public var body: some View {
		MobileShellBody(
			hosts: hostStore.binding,
			snippets: snippetBinding,
			remoteEntries: $remoteEntries,
			transfers: $transfers,
			settingsStore: settingsStore,
			terminalPreferences: terminalPreferences,
			remoteFileClientFactory: remoteFileClientFactory,
			fileTransferStore: fileTransferStore,
			transferWorkspace: transferWorkspace
		)
		.environment(\.mobileHostSave, MobileHostSaveAction(
			save: { payload in
				do {
					try await hostSaveCoordinator.save(payload)
					return true
				} catch {
					operationError = MobileHostOperationError(
						title: "Couldn’t Save Host",
						error: error
					)
					return false
				}
			},
			deleteHost: { id in
				do {
					try await hostStore.delete(id: id)
					return true
				} catch {
					operationError = MobileHostOperationError(
						title: "Couldn’t Delete Host",
						error: error
					)
					return false
				}
			}
		))
		.environment(\.mobileTerminalSessionFactory, terminalSessionFactory)
		.environment(\.mobileSnippetMutation, MobileSnippetMutationAction(
			upsert: { snippet in
				try snippetSyncRuntime.upsert(snippet)
			},
			delete: { id in
				try snippetSyncRuntime.delete(id: id)
			},
			move: { offsets, destination in
				try snippetSyncRuntime.move(
					fromOffsets: offsets,
					toOffset: destination
				)
			}
		))
		.environment(\.mobileBackupImportAction, MobileBackupImportAction(
			apply: { payload, snippets in
				try await backupImportCoordinator.apply(
					payload: payload,
					snippets: snippets
				)
			}
		))
		.environment(
			\.mobileSyncStatus,
			syncCoordinator.isAvailable ? syncCoordinator.status : nil
		)
		.environment(\.mobileSyncAction, mobileSyncAction)
		.refreshable {
			await syncCoordinator.pullToRefresh()
		}
		.task {
			await syncCoordinator.launch()
		}
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			Task {
				await syncCoordinator.becameActive()
			}
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .catermICloudAccountChanged)
		) { _ in
			Task {
				await syncCoordinator.accountChanged()
			}
		}
		.alert(item: $operationError) { failure in
			Alert(
				title: Text(failure.title),
				message: Text(failure.message),
				dismissButton: .default(Text("OK"))
			)
		}
		.onReceive(hostStore.$lastPersistenceFailure.compactMap { $0 }) { failure in
			operationError = MobileHostOperationError(
				title: "Couldn’t Save Hosts",
				error: failure.underlyingError
			)
			hostStore.clearPersistenceFailure()
		}
	}

	private var snippetBinding: Binding<[Snippet]> {
		Binding(
			get: { snippetStore.snippets },
			set: { newSnippets in
				do {
					try snippetSyncRuntime.replaceLocalSnapshot(newSnippets)
				} catch {
					operationError = MobileHostOperationError(
						title: "Couldn’t Save Snippets",
						error: error
					)
				}
			}
		)
	}

	private var terminalPreferences: MobileTerminalPreferences {
		let global = settingsStore.effectiveSettings.global
		return MobileTerminalPreferences(
			themeID: global.theme ?? TerminalTheme.presets[0].id,
			fontSize: Double(
				global.fontSize ?? Int(MobileTerminalSettings.defaultFontSize)
			),
			keyboardMode: global.prefersNativeMobileKeyboard == true
				? .native
				: .custom
		)
	}

	private var mobileSyncAction: MobileSyncAction? {
		guard syncCoordinator.isAvailable else { return nil }
		return MobileSyncAction(syncNow: {
			await syncCoordinator.syncNow()
		})
	}
}

struct MobileSyncStatusView: View {
	private enum RecoveryAction: Equatable {
		case retry
		case signInHelp
	}

	let status: MobileSyncStatus
	@Environment(\.mobileSyncAction) private var syncAction
	@State private var showingSignInHelp = false

	var body: some View {
		switch status {
		case .upToDate:
			EmptyView()
		case .checkingAccount:
			statusRow("Checking iCloud…", systemImage: "icloud", progress: true)
		case .syncing:
			statusRow("Syncing with iCloud…", systemImage: "arrow.triangle.2.circlepath", progress: true)
		case .signedOut:
			statusRow(
				"Available offline. Sign in to iCloud to sync.",
				systemImage: "icloud.slash",
				recovery: .signInHelp
			)
			.alert("Sign In to iCloud", isPresented: $showingSignInHelp) {
				Button("OK", role: .cancel) {}
			} message: {
				Text("Open the Settings app, tap your name or Sign in to your iPhone or iPad, sign in to iCloud, then return to Caterm and tap Sync Now.")
			}
		case let .temporarilyUnavailable(message):
			statusRow(message, systemImage: "exclamationmark.icloud", recovery: .retry)
		case let .failed(message):
			statusRow(message, systemImage: "exclamationmark.triangle", recovery: .retry)
		}
	}

	@ViewBuilder
	private func statusRow(
		_ text: String,
		systemImage: String,
		progress: Bool = false,
		recovery: RecoveryAction? = nil
	) -> some View {
		let content = HStack(spacing: 8) {
			if progress {
				ProgressView()
					.controlSize(.small)
					.accessibilityHidden(true)
			} else {
				Image(systemName: systemImage)
					.accessibilityHidden(true)
			}
			Text(text)
				.font(.footnote)
				.lineLimit(2)
				.accessibilityLabel(status.accessibilityDescription)
			Spacer(minLength: 0)
			if let recovery {
				Button(recovery == .retry ? "Retry" : "Sign-In Help") {
					recover(using: recovery)
				}
				.buttonStyle(.borderless)
				.accessibilityHint(recovery == .retry
					? "Attempts iCloud synchronization again"
					: "Shows the steps for signing in to iCloud")
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)

		if recovery != nil {
			content.accessibilityElement(children: .contain)
		} else {
			content
				.accessibilityElement(children: .combine)
				.accessibilityLabel(status.accessibilityDescription)
		}
	}

	private func recover(using action: RecoveryAction) {
		switch action {
		case .retry:
			guard let syncAction else { return }
			Task { await syncAction.syncNow() }
		case .signInHelp:
			showingSignInHelp = true
		}
	}
}

public struct MobileSyncAction: Sendable {
	public let syncNow: @MainActor @Sendable () async -> Void

	public init(syncNow: @escaping @MainActor @Sendable () async -> Void) {
		self.syncNow = syncNow
	}
}

private struct MobileSyncStatusEnvironmentKey: EnvironmentKey {
	static let defaultValue: MobileSyncStatus? = nil
}

private struct MobileSyncActionEnvironmentKey: EnvironmentKey {
	static let defaultValue: MobileSyncAction? = nil
}

extension EnvironmentValues {
	var mobileSyncStatus: MobileSyncStatus? {
		get { self[MobileSyncStatusEnvironmentKey.self] }
		set { self[MobileSyncStatusEnvironmentKey.self] = newValue }
	}

	var mobileSyncAction: MobileSyncAction? {
		get { self[MobileSyncActionEnvironmentKey.self] }
		set { self[MobileSyncActionEnvironmentKey.self] = newValue }
	}
}

private struct MobileHostOperationError: Identifiable {
	let id = UUID()
	let title: String
	let message: String

	init(title: String, error: any Error) {
		self.title = title
		self.message = error.localizedDescription
	}
}

struct MobileShellBody: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.mobileHostSave) private var hostSave
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]
	@Binding var remoteEntries: [RemoteEntry]
	@Binding var transfers: [TransferTask]
	let settingsStore: SettingsStore?
	let terminalPreferences: MobileTerminalPreferences
	let remoteFileClientFactory: MobileRemoteFileClientFactory
	let fileTransferStore: FileTransferStore?
	let transferWorkspace: MobileTransferWorkspace?
	@State private var selection: MobileShellSelection?
	@State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
	@State private var showingAddHost = false

	var body: some View {
		Group {
			if horizontalSizeClass == .compact {
				MobileCompactShell(
					hosts: $hosts,
					snippets: $snippets,
					remoteEntries: $remoteEntries,
					transfers: $transfers,
					settingsStore: settingsStore,
					terminalPreferences: terminalPreferences,
					remoteFileClientFactory: remoteFileClientFactory,
					fileTransferStore: fileTransferStore,
					transferWorkspace: transferWorkspace
				)
			} else {
				NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
					MobileShellSidebar(
						hosts: hosts,
						selection: $selection,
						showingAddHost: $showingAddHost
					)
				} detail: {
					MobileShellDetail(
						selection: $selection,
						hosts: $hosts,
						snippets: $snippets,
						remoteEntries: $remoteEntries,
						transfers: $transfers,
						settingsStore: settingsStore,
						terminalPreferences: terminalPreferences,
						remoteFileClientFactory: remoteFileClientFactory,
						fileTransferStore: fileTransferStore,
						transferWorkspace: transferWorkspace
					)
				}
				.sheet(isPresented: $showingAddHost) {
					NavigationStack {
						MobileHostFormView(mode: .add, allHosts: hosts) { payload in
							if let hostSave {
								Task { @MainActor in
									guard await hostSave.save(payload) else { return }
									selection = .host(payload.host.id)
									showingAddHost = false
								}
							} else {
								hosts.append(payload.host)
								selection = .host(payload.host.id)
								showingAddHost = false
							}
						}
					}
				}
			}
		}
		.onAppear {
			if selection == nil { selection = hosts.first.map { .host($0.id) } }
		}
	}
}

private enum MobileShellSelection: Hashable {
	case host(UUID)
	case terminal(UUID)
	case credential(UUID)
	case snippets
	case files
	case settings
}

private struct MobileCompactShell: View {
	@Environment(\.mobileHostSave) private var hostSave
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]
	@Binding var remoteEntries: [RemoteEntry]
	@Binding var transfers: [TransferTask]
	let settingsStore: SettingsStore?
	let terminalPreferences: MobileTerminalPreferences
	let remoteFileClientFactory: MobileRemoteFileClientFactory
	let fileTransferStore: FileTransferStore?
	let transferWorkspace: MobileTransferWorkspace?
	@State private var showingAddHost = false

	var body: some View {
		TabView {
			NavigationStack {
				ZStack(alignment: .bottomTrailing) {
					MobileHostsView(
						hosts: $hosts,
						snippets: snippets,
						terminalPreferences: terminalPreferences
					)

					Button {
						showingAddHost = true
					} label: {
						Label("Add Host", systemImage: "plus")
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.padding(16)
				}
			}
			.tabItem { Label("Hosts", systemImage: "server.rack") }

			NavigationStack {
				MobileSnippetsView(snippets: $snippets)
			}
			.tabItem { Label("Snippets", systemImage: "text.cursor") }

			NavigationStack {
				MobileFileBrowserView(
					hosts: hosts,
					clientFactory: remoteFileClientFactory,
					entries: remoteEntries,
					transfers: transfers,
					transferStore: fileTransferStore,
					transferWorkspace: transferWorkspace
				)
			}
			.tabItem { Label("Files", systemImage: "folder") }

			NavigationStack {
				MobileSettingsView(
					hosts: $hosts,
					snippets: $snippets,
					settingsStore: settingsStore
				)
			}
			.tabItem { Label("Settings", systemImage: "gearshape") }
		}
		.sheet(isPresented: $showingAddHost) {
			NavigationStack {
				MobileHostFormView(mode: .add, allHosts: hosts) { payload in
					if let hostSave {
						Task { @MainActor in
							guard await hostSave.save(payload) else { return }
							showingAddHost = false
						}
					} else {
						hosts.append(payload.host)
						showingAddHost = false
					}
				}
			}
		}
	}
}

private struct MobileShellSidebar: View {
	let hosts: [SSHHost]
	@Binding var selection: MobileShellSelection?
	@Binding var showingAddHost: Bool

	var body: some View {
		List(selection: $selection) {
			Section("Hosts") {
				if hosts.isEmpty {
					Label("No hosts", systemImage: "server.rack")
						.foregroundStyle(.secondary)
				} else {
					ForEach(hosts) { host in
						Label(host.name, systemImage: "server.rack")
							.tag(MobileShellSelection.host(host.id))
					}
				}
			}

			Section("Tools") {
				Label("Snippets", systemImage: "text.cursor")
					.tag(MobileShellSelection.snippets)
				Label("Files", systemImage: "folder")
					.tag(MobileShellSelection.files)
				Label("Settings", systemImage: "gearshape")
					.tag(MobileShellSelection.settings)
			}
		}
		.navigationTitle("Caterm")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					showingAddHost = true
				} label: {
					Image(systemName: "plus")
				}
				.accessibilityLabel("Add Host")
			}
		}
	}
}

private struct MobileShellDetail: View {
	@Environment(\.mobileTerminalSessionFactory) private var terminalSessionFactory
	@Environment(\.mobileHostSave) private var hostSave
	@Binding var selection: MobileShellSelection?
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]
	@Binding var remoteEntries: [RemoteEntry]
	@Binding var transfers: [TransferTask]
	let settingsStore: SettingsStore?
	let terminalPreferences: MobileTerminalPreferences
	let remoteFileClientFactory: MobileRemoteFileClientFactory
	let fileTransferStore: FileTransferStore?
	let transferWorkspace: MobileTransferWorkspace?

	var body: some View {
		switch selection {
		case .host(let id):
			if let binding = binding(for: id) {
				MobileHostDetailView(
					host: binding.wrappedValue,
					snippets: snippets,
					terminalPreferences: terminalPreferences,
					onConnect: { route in
						switch route {
						case .credentialSetup(let hostId):
							selection = .credential(hostId)
						case .terminalPlaceholder(let hostId):
							selection = .terminal(hostId)
						case .detail(let hostId), .edit(let hostId):
							selection = .host(hostId)
						}
					},
					onDelete: {
						if let hostSave {
							Task { @MainActor in
								if await hostSave.deleteHost(id) {
									selection = nil
								}
							}
						} else {
							hosts.removeAll { $0.id == id }
							selection = nil
						}
					},
					onUpdate: { updated in
						if let index = hosts.firstIndex(where: { $0.id == updated.id }) {
							hosts[index] = updated
						}
					}
				)
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .terminal(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				#if canImport(UIKit)
				MobileTerminalSessionView(
					initialHost: host,
					hosts: hosts,
					snippets: snippets.map {
						TerminalSnippet(id: $0.id, name: $0.name, command: $0.content)
					},
					preferences: terminalPreferences
					) {
						if let terminalSessionFactory {
							return try await terminalSessionFactory.make($0)
						}
						return try await MobileHostsView.fallbackSession(for: $0)
					}
				#else
				MobileTerminalPlaceholderView(host: host, snippet: nil)
				#endif
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .credential(let id):
			MobileCredentialSetupPlaceholderView(host: hosts.first { $0.id == id })
		case .snippets:
			MobileSnippetsView(snippets: $snippets)
		case .files:
			MobileFileBrowserView(
				hosts: hosts,
				clientFactory: remoteFileClientFactory,
				entries: remoteEntries,
				transfers: transfers,
				transferStore: fileTransferStore,
				transferWorkspace: transferWorkspace
			)
		case .settings:
			MobileSettingsView(
				hosts: $hosts,
				snippets: $snippets,
				settingsStore: settingsStore
			)
		case nil:
			MobileHostsView(
				hosts: $hosts,
				snippets: snippets,
				terminalPreferences: terminalPreferences
			)
		}
	}

	private func binding(for id: UUID) -> Binding<SSHHost>? {
		guard let index = hosts.firstIndex(where: { $0.id == id }) else { return nil }
		return $hosts[index]
	}
}
