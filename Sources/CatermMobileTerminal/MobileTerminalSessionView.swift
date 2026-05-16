#if canImport(UIKit)
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
	public init(id: UUID, name: String, command: String) {
		self.id = id
		self.name = name
		self.command = command
	}
}

public enum TerminalKeyboardMode: Equatable {
	case custom
	case native
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

	public let terminalView: TerminalView
	private let coordinator = TerminalCoordinator()
	public private(set) var session: SSHTerminalSession?
	private let make: (SSHHost) -> SSHTerminalSession
	private var started = false

	public init(host: SSHHost, makeSession: @escaping (SSHHost) -> SSHTerminalSession) {
		self.host = host
		self.title = host.name
		self.make = makeSession
		let tv = TerminalView(frame: .init(x: 0, y: 0, width: 400, height: 600))
		tv.backgroundColor = .black
		self.terminalView = tv
		coordinator.model = self
		coordinator.terminalView = tv
		tv.terminalDelegate = coordinator
		applyTheme(TerminalTheme.presets[0])
	}

	public func start() {
		guard !started else { return }
		started = true
		let s = make(host)
		s.onStateChange = { [weak self] st in
			Task { @MainActor in self?.state = st }
		}
		s.onOutput = { [weak self] bytes in
			Task { @MainActor in self?.coordinator.feed(bytes) }
		}
		session = s
		Task { await s.connect() }
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
		Task { await session?.disconnect() }
	}
}

/// Holds every open terminal tab. Switching tabs only changes which
/// retained `TerminalScreenModel` is shown; the others keep running.
@MainActor
public final class TerminalSessionsModel: ObservableObject {
	@Published public private(set) var tabs: [TerminalScreenModel] = []
	@Published public var selectedID: UUID?
	@Published public var keyboardMode: TerminalKeyboardMode = .custom

	private let makeSession: (SSHHost) -> SSHTerminalSession

	public init(initialHost: SSHHost, makeSession: @escaping (SSHHost) -> SSHTerminalSession) {
		self.makeSession = makeSession
		addTab(host: initialHost)
	}

	public var selected: TerminalScreenModel? {
		tabs.first { $0.id == selectedID } ?? tabs.first
	}

	@discardableResult
	public func addTab(host: SSHHost) -> TerminalScreenModel {
		let model = TerminalScreenModel(host: host, makeSession: makeSession)
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

/// The whole terminal surface: tab strip + the Termius-style keyboard
/// and tool toolbar. `+` opens another host as a live tab.
public struct MobileTerminalSessionView: View {
	@StateObject private var sessions: TerminalSessionsModel
	@Environment(\.dismiss) private var dismiss
	@State private var showingHostPicker = false

	private let hosts: [SSHHost]
	private let snippets: [TerminalSnippet]

	public init(
		initialHost: SSHHost,
		hosts: [SSHHost] = [],
		snippets: [TerminalSnippet] = [],
		makeSession: @escaping (SSHHost) -> SSHTerminalSession
	) {
		self.hosts = hosts
		self.snippets = snippets
		_sessions = StateObject(wrappedValue: TerminalSessionsModel(
			initialHost: initialHost, makeSession: makeSession))
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
		.toolbar(.hidden, for: .tabBar)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button("Disconnect", role: .destructive) {
					sessions.closeAll()
					dismiss()
				}
			}
		}
		.sheet(isPresented: $showingHostPicker) {
			hostPicker
		}
	}

	@ViewBuilder private func terminalArea(_ model: TerminalScreenModel) -> some View {
		ZStack {
			SwiftTermBridge(model: model)
				.ignoresSafeArea(.container, edges: .bottom)
			connectionOverlay(model)
		}
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

	private var tabStrip: some View {
		HStack(spacing: 8) {
			Button {
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

			Button {
				let next: TerminalKeyboardMode = sessions.keyboardMode == .custom ? .native : .custom
				sessions.keyboardMode = next
				sessions.selected?.setNativeKeyboard(next == .native)
			} label: {
				Text(sessions.keyboardMode == .custom ? "ABC" : "⌨︎")
					.font(.system(.callout, design: .rounded).weight(.semibold))
			}
			.accessibilityLabel("Toggle Keyboard")
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
		switch model.state {
		case .connecting, .idle:
			ProgressView("Connecting…")
				.padding()
				.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
		case let .failed(reason):
			ContentUnavailableView("Connection Failed", systemImage: "xmark.octagon", description: Text(reason))
		case let .disconnected(reason):
			ContentUnavailableView("Disconnected", systemImage: "bolt.horizontal.circle", description: Text(reason))
		case let .authPrompt(missing):
			ContentUnavailableView("Credential Needed", systemImage: "key", description: Text("Missing \(String(describing: missing)); set it on the host and reconnect."))
		case .hostKeyPrompt, .connected:
			EmptyView()
		}
	}

	private var hostPicker: some View {
		NavigationStack {
			List(hosts, id: \.id) { h in
				Button {
					sessions.addTab(host: h)
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
