#if canImport(UIKit)
import HostAutomationRuntime
import SSHCommandBuilder
import SwiftTerm
import SwiftUI
import UIKit

/// Lightweight snippet DTO so the terminal module stays independent of
/// SnippetSyncClient. Call sites map their own model into this.
public struct TerminalSnippet: Identifiable, Equatable, Sendable {
	public let id: UUID
	public let name: String
	public let command: String
	public let placeholders: [String]

	public init(
		id: UUID,
		name: String,
		command: String,
		placeholders: [String] = []
	) {
		self.id = id
		self.name = name
		self.command = command
		self.placeholders = placeholders
	}
}

/// Owns one SSH session **and its retained SwiftTerm view**, so a tab can
/// scroll off-screen without dropping the connection or scrollback.
@MainActor
public final class TerminalScreenModel: ObservableObject, Identifiable {
	public let id = UUID()
	public let host: SSHHost
	public let title: String

	@Published public var state: SSHTerminalSession.State = .idle
	@Published public var keyBar = TerminalKeyBar()
	@Published public private(set) var recents: [String] = []
	@Published public var theme: TerminalTheme = TerminalTheme.presets[0]
	@Published public private(set) var automationGate: HostAutomationConnectionGate
	@Published public private(set) var environmentRequestStatus:
		HostEnvironmentRequestStatus = .notRequested

	public let terminalView: TerminalView
	private let coordinator = TerminalCoordinator()
	public private(set) var session: SSHTerminalSession?
	private let make: @MainActor (SSHHost) async throws -> SSHTerminalSession
	private var started = false
	private var startupTask: Task<Void, Never>?
	private var startupGeneration: UInt64 = 0
	private var automationController: HostAutomationSessionController

	public init(
		host: SSHHost,
		preferences: MobileTerminalPreferences = .storedDefaults,
		automationResolution: HostAutomationResolution = .disabled,
		makeSession: @escaping @MainActor (SSHHost) async throws -> SSHTerminalSession
	) {
		self.host = host
		self.title = host.name
		self.make = makeSession
		let automationController = HostAutomationSessionController(
			resolution: automationResolution
		)
		self.automationController = automationController
		self.automationGate = automationController.gate
		let tv = TerminalView(frame: .init(x: 0, y: 0, width: 400, height: 600))
		tv.backgroundColor = .black
		tv.font = UIFont.monospacedSystemFont(
			ofSize: preferences.fontSize, weight: .regular)
		// SwiftTerm installs its own input-accessory key bar; suppress it
		// so native-keyboard mode shows only our TerminalAccessoryRow
		// (otherwise two near-identical esc/ctrl/tab/arrow rows stack).
		tv.inputAccessoryView = nil
		self.terminalView = tv
		coordinator.model = self
		coordinator.terminalView = tv
		tv.terminalDelegate = coordinator
		applyTheme(preferences.theme)
	}

	public func start() {
		guard !started else { return }
		guard automationController.canConnect else { return }
		started = true
		startupGeneration &+= 1
		let generation = startupGeneration
		state = .connecting
		startupTask = Task { @MainActor [weak self] in
			guard let self else { return }
			do {
				var connectionHost = host
				let environment = automationController.environment
				connectionHost.automation = HostAutomation(
					isEnabled: !environment.isEmpty,
					environment: environment,
					reviewPolicy: .never
				)
				let session = try await make(connectionHost)
				try Task.checkCancellation()
				guard started, generation == startupGeneration else {
					await session.disconnect()
					return
				}
				session.onStateChange = { [weak self] state in
					Task { @MainActor [weak self, weak session] in
						guard let self,
						      let session,
						      self.started,
						      generation == self.startupGeneration,
						      self.session === session else {
							return
						}
						self.state = state
						if state == .connected {
							await self.runStartupCommandIfNeeded(
								on: session,
								generation: generation
							)
						}
					}
				}
				session.onOutput = { [weak self, weak session] bytes in
					Task { @MainActor [weak self, weak session] in
						guard let self,
						      let session,
						      self.started,
						      generation == self.startupGeneration,
						      self.session === session else {
							return
						}
						self.coordinator.feed(bytes)
					}
				}
				session.onEnvironmentStatusChange = { [weak self, weak session] status in
					Task { @MainActor [weak self, weak session] in
						guard let self,
						      let session,
						      self.started,
						      generation == self.startupGeneration,
						      self.session === session else {
							return
						}
						self.environmentRequestStatus = status
					}
				}
				self.session = session
				await session.connect()
			} catch is CancellationError {
				if generation == self.startupGeneration {
					self.started = false
				}
			} catch {
				if generation == self.startupGeneration {
					self.state = .failed(reason: error.localizedDescription)
				}
			}
		}
	}

	public func approveAutomation() {
		let wasConnectable = automationController.canConnect
		automationController.approve()
		automationGate = automationController.gate
		if !wasConnectable, automationController.canConnect {
			start()
		}
	}

	public func connectWithoutAutomation() {
		let wasConnectable = automationController.canConnect
		automationController.suppress()
		automationGate = automationController.gate
		environmentRequestStatus = .notRequested
		if !wasConnectable, automationController.canConnect {
			start()
		}
	}

	private func runStartupCommandIfNeeded(
		on session: SSHTerminalSession,
		generation: UInt64
	) async {
		guard let command = automationController.startupCommand(
			sessionGeneration: Int(truncatingIfNeeded: generation)
		) else {
			return
		}
		var bytes = Array(command.utf8)
		if bytes.last != 0x0a {
			bytes.append(0x0a)
		}
		await session.send(bytes)
	}

	public func tapKey(_ key: TerminalKeyBar.Key) {
		if key == .paste {
			paste()
			return
		}
		let bytes = keyBar.bytes(for: key)
		objectWillChange.send()
		guard !bytes.isEmpty else { return }
		Task { await session?.send(bytes) }
	}

	public func paste() {
		guard let s = UIPasteboard.general.string, !s.isEmpty else { return }
		Task { await session?.send(Array(s.utf8)) }
	}

	/// Sends snippet/command text, appending a newline so it executes.
	public func runText(_ text: String) {
		var bytes = Array(text.utf8)
		if bytes.last != 0x0a { bytes.append(0x0a) }
		recents.removeAll { $0 == text }
		recents.insert(text, at: 0)
		if recents.count > 20 { recents.removeLast() }
		Task { await session?.send(bytes) }
	}

	public func setNativeKeyboard(_ on: Bool) {
		if on { _ = terminalView.becomeFirstResponder() }
		else { _ = terminalView.resignFirstResponder() }
	}

	public func applyTheme(_ theme: TerminalTheme) {
		self.theme = theme
		if let fg = UIColor(hex: theme.foreground) { terminalView.nativeForegroundColor = fg }
		if let cur = UIColor(hex: theme.cursor) { terminalView.caretColor = cur }
		let ansi = theme.ansi.compactMap { SwiftTerm.Color(hex: $0) }
		if ansi.count == 16 { terminalView.installColors(ansi) }
		// Set last: this setter is the one that calls SwiftTerm's
		// colorsChanged() and forces a full repaint with the new palette.
		if let bg = UIColor(hex: theme.background) {
			terminalView.backgroundColor = bg
			terminalView.nativeBackgroundColor = bg
		}
		terminalView.setNeedsDisplay(terminalView.bounds)
	}

	public func disconnect() {
		startupGeneration &+= 1
		startupTask?.cancel()
		startupTask = nil
		started = false
		Task { await session?.disconnect() }
	}

	/// Tears down the current session (if any) and dials again, reusing
	/// the same retained terminal view/scrollback.
	public func reconnect() {
		startupGeneration &+= 1
		let generation = startupGeneration
		startupTask?.cancel()
		startupTask = nil
		let old = session
		// Detach first: a disconnecting session emits a late .closed that
		// would otherwise clobber the fresh session's .connected state.
		old?.onStateChange = nil
		old?.onOutput = nil
		old?.onEnvironmentStatusChange = nil
		session = nil
		started = false
		environmentRequestStatus = .notRequested
		// Switch to the connecting UI synchronously so the tap has
		// immediate, visible feedback instead of briefly looking dead.
		state = .connecting
		Task {
			await old?.disconnect()
			guard generation == startupGeneration else { return }
			start()
		}
	}
}

/// Holds every open terminal tab. Switching tabs only changes which
/// retained `TerminalScreenModel` is shown; the others keep running.
@MainActor
public final class TerminalSessionsModel: ObservableObject {
	@Published public private(set) var tabs: [TerminalScreenModel] = []
	@Published public var selectedID: UUID?
	@Published public var keyboardMode: TerminalKeyboardMode = .custom

	private let makeSession: @MainActor (SSHHost) async throws -> SSHTerminalSession
	private let automationSnippets: [HostAutomationSnippet]

	public init(
		initialHost: SSHHost,
		preferences: MobileTerminalPreferences = .storedDefaults,
		automationSnippets: [HostAutomationSnippet] = [],
		makeSession: @escaping @MainActor (SSHHost) async throws -> SSHTerminalSession
	) {
		self.makeSession = makeSession
		self.automationSnippets = automationSnippets
		self.keyboardMode = preferences.keyboardMode
		addTab(host: initialHost, preferences: preferences)
	}

	public var selected: TerminalScreenModel? {
		tabs.first { $0.id == selectedID } ?? tabs.first
	}

	@discardableResult
	public func addTab(
		host: SSHHost,
		preferences: MobileTerminalPreferences = .storedDefaults
	) -> TerminalScreenModel {
		let model = TerminalScreenModel(
			host: host,
			preferences: preferences,
			automationResolution: HostAutomationResolver.resolve(
				host: host,
				automationSnippets: automationSnippets
			),
			makeSession: makeSession
		)
		tabs.append(model)
		selectedID = model.id
		model.start()
		return model
	}

	public func select(_ id: UUID) {
		selectedID = id
	}

	public func closeTab(_ id: UUID) {
		guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
		tabs[idx].disconnect()
		tabs.remove(at: idx)
		if selectedID == id {
			selectedID = tabs.isEmpty ? nil : tabs[max(0, idx - 1)].id
		}
	}

	public func closeAll() {
		for t in tabs { t.disconnect() }
	}
}

/// The terminal viewport: the retained SwiftTerm view with the
/// connection overlay stacked on top. Observes the model directly so a
/// state change re-renders the hit-testing gate — when the session is
/// not connected the terminal's UIScrollView stops swallowing touches,
/// letting the overlay's Reconnect button receive taps.
struct TerminalPane<Overlay: View>: View {
	@ObservedObject var model: TerminalScreenModel
	@ViewBuilder let overlay: () -> Overlay

	var body: some View {
		ZStack {
			SwiftTermBridge(model: model)
				.ignoresSafeArea(.container, edges: .bottom)
				.allowsHitTesting(model.state == .connected)
			overlay()
		}
	}
}

/// The whole terminal surface: tab strip + the Termius-style keyboard
/// and tool toolbar. `+` opens another host as a live tab.
public struct MobileTerminalSessionView: View {
	@StateObject private var sessions: TerminalSessionsModel
	@Environment(\.dismiss) private var dismiss
	@State private var showingHostPicker = false

	private let hosts: [SSHHost]
	private let snippets: [TerminalSnippet]
	private let preferences: MobileTerminalPreferences

	public init(
		initialHost: SSHHost,
		hosts: [SSHHost] = [],
		snippets: [TerminalSnippet] = [],
		preferences: MobileTerminalPreferences = .storedDefaults,
		makeSession: @escaping @MainActor (SSHHost) async throws -> SSHTerminalSession
	) {
		self.hosts = hosts
		self.snippets = snippets
		self.preferences = preferences
		_sessions = StateObject(wrappedValue: TerminalSessionsModel(
			initialHost: initialHost,
			preferences: preferences,
			automationSnippets: snippets.map {
				HostAutomationSnippet(
					id: $0.id,
					name: $0.name,
					content: $0.command,
					placeholders: $0.placeholders
				)
			},
			makeSession: makeSession
		))
	}

	public var body: some View {
		VStack(spacing: 0) {
			tabStrip
			Group {
				if let model = sessions.selected {
					terminalArea(model)
				} else {
					ContentUnavailableView("No Session", systemImage: "terminal")
				}
			}
		}
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .tabBar)
		.toolbar(.hidden, for: .navigationBar)
		.sheet(isPresented: $showingHostPicker) {
			hostPicker
		}
	}

	@ViewBuilder private func terminalArea(_ model: TerminalScreenModel) -> some View {
		TerminalPane(model: model) { connectionOverlay(model) }
		if showsTerminalControls(for: model.automationGate) {
			if sessions.keyboardMode == .custom {
				TerminalKeyGridView(model: model)
			} else {
				TerminalAccessoryRow(model: model)
			}
			TerminalToolbarView(
				model: model,
				snippets: snippets,
				keyboardMode: $sessions.keyboardMode
			)
		}
	}

	private func showsTerminalControls(
		for gate: HostAutomationConnectionGate
	) -> Bool {
		switch gate {
		case .reviewRequired, .blocked:
			false
		case .inactive, .approved, .suppressed:
			true
		}
	}

	private var tabStrip: some View {
		HStack(spacing: 8) {
			Button {
				sessions.closeAll()
				dismiss()
			} label: {
				Image(systemName: "chevron.left")
			}
			.accessibilityLabel("Back")

			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 6) {
					ForEach(sessions.tabs) { tab in
						tabChip(tab)
					}
				}
			}

			Button {
				showingHostPicker = true
			} label: {
				Image(systemName: "plus")
			}
			.accessibilityLabel("New Connection")
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(.bar)
	}

	private func tabChip(_ tab: TerminalScreenModel) -> some View {
		let isSel = tab.id == sessions.selectedID
		return HStack(spacing: 6) {
			Circle()
				.fill(statusColor(tab.state))
				.frame(width: 7, height: 7)
			Text(tab.title)
				.font(.callout)
				.lineLimit(1)
			Button {
				sessions.closeTab(tab.id)
			} label: {
				Image(systemName: "xmark")
					.font(.caption2)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Close \(tab.title)")
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(
			isSel ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.secondary.opacity(0.12),
			in: Capsule())
		.contentShape(Capsule())
		.onTapGesture { sessions.select(tab.id) }
	}

	private func statusColor(_ s: SSHTerminalSession.State) -> SwiftUI.Color {
		switch s {
		case .connected: .green
		case .connecting, .idle: .yellow
		case .failed, .disconnected: .red
		case .authPrompt, .hostKeyPrompt: .orange
		}
	}

	@ViewBuilder private func connectionOverlay(_ model: TerminalScreenModel) -> some View {
		switch model.automationGate {
		case .reviewRequired(let plan):
			mobileAutomationReview(plan, model: model)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(.systemBackground))
		case .blocked(let reason):
			mobileAutomationBlocked(reason, model: model)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(.systemBackground))
		case .inactive, .approved, .suppressed:
			connectionStateOverlay(model)
		}
	}

	@ViewBuilder private func connectionStateOverlay(
		_ model: TerminalScreenModel
	) -> some View {
		switch model.state {
		case .connected:
			mobileEnvironmentStatus(model.environmentRequestStatus)
		case .hostKeyPrompt:
			EmptyView()
		default:
			overlayContent(model)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(.systemBackground))
		}
	}

	private func mobileAutomationReview(
		_ plan: HostAutomationSessionPlan,
		model: TerminalScreenModel
	) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				Label("Review Host Automation", systemImage: "checklist")
					.font(.title2.weight(.semibold))
				if let command = plan.startupCommand {
					VStack(alignment: .leading, spacing: 6) {
						Text(plan.startupSnippetName ?? "Startup Command")
							.font(.headline)
						Text(command)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(12)
							.background(
								Color.secondary.opacity(0.12),
								in: RoundedRectangle(cornerRadius: 10)
							)
					}
				}
				if !plan.environment.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text("Remote Environment").font(.headline)
						ForEach(plan.environment) { variable in
							LabeledContent(variable.name, value: variable.value)
								.font(.system(.body, design: .monospaced))
						}
					}
				}
				Button("Run Automation & Connect") {
					model.approveAutomation()
				}
				.buttonStyle(.borderedProminent)
				.frame(maxWidth: .infinity)
				Button("Connect Without Automation") {
					model.connectWithoutAutomation()
				}
				.frame(maxWidth: .infinity)
			}
			.padding(24)
		}
	}

	private func mobileAutomationBlocked(
		_ reason: HostAutomationUnresolvedReason,
		model: TerminalScreenModel
	) -> some View {
		ContentUnavailableView {
			Label("Automation Needs Attention", systemImage: "exclamationmark.triangle")
		} description: {
			Text(reason.message)
		} actions: {
			Button("Connect Without Automation") {
				model.connectWithoutAutomation()
			}
			.buttonStyle(.borderedProminent)
		}
		.padding()
	}

	@ViewBuilder
	private func mobileEnvironmentStatus(
		_ status: HostEnvironmentRequestStatus
	) -> some View {
		switch status {
		case .completed(_, let rejected) where !rejected.isEmpty:
			VStack {
				Label(
					"Server rejected environment: \(rejected.joined(separator: ", "))",
					systemImage: "exclamationmark.triangle"
				)
				.font(.caption)
				.padding(10)
				.background(.regularMaterial, in: Capsule())
				.padding()
				Spacer()
			}
		case .pending(let names):
			VStack {
				Label(
					"Waiting for environment: \(names.joined(separator: ", "))",
					systemImage: "clock"
				)
				.font(.caption)
				.padding(10)
				.background(.regularMaterial, in: Capsule())
				.padding()
				Spacer()
			}
		case .notRequested, .sentUnverified, .completed:
			EmptyView()
		}
	}

	@ViewBuilder private func overlayContent(_ model: TerminalScreenModel) -> some View {
		switch model.state {
		case .connecting, .idle:
			ContentUnavailableView {
				Label("Connecting…", systemImage: "network")
			} description: {
				ProgressView()
					.controlSize(.large)
					.padding(.top, 6)
			}
		case let .failed(reason):
			failureView("Connection Failed", "xmark.octagon", reason, model)
		case let .disconnected(reason):
			failureView("Disconnected", "bolt.horizontal.circle", reason, model)
		case let .authPrompt(missing):
			failureView(
				"Credential Needed", "key",
				"Missing \(String(describing: missing)). Set it on the host, then reconnect.",
				model)
		case .connected, .hostKeyPrompt:
			EmptyView()
		}
	}

	private func failureView(
		_ title: String, _ icon: String, _ message: String,
		_ model: TerminalScreenModel
	) -> some View {
		VStack(spacing: 20) {
			ContentUnavailableView {
				Label(title, systemImage: icon)
			} description: {
				Text(message).textSelection(.enabled)
			}
			.fixedSize(horizontal: false, vertical: true)

			Button {
				model.reconnect()
			} label: {
				Label("Reconnect", systemImage: "arrow.clockwise")
					.font(.body.weight(.semibold))
					.padding(.horizontal, 24)
					.padding(.vertical, 12)
			}
			.buttonStyle(.borderedProminent)
		}
		.padding()
	}

	private var hostPicker: some View {
		NavigationStack {
			List(hosts, id: \.id) { h in
				Button {
					sessions.addTab(host: h, preferences: preferences)
					showingHostPicker = false
				} label: {
					VStack(alignment: .leading) {
						Text(h.name).font(.headline)
						Text("\(h.username)@\(h.hostname)")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
			}
			.navigationTitle("Open Connection")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { showingHostPicker = false }
				}
			}
		}
	}
}
#endif
