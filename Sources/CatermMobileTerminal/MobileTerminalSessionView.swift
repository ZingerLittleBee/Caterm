#if canImport(UIKit)
import SwiftUI

@MainActor
public final class TerminalScreenModel: ObservableObject {
	@Published public var state: SSHTerminalSession.State = .idle
	@Published public var keyBar = TerminalKeyBar()
	public private(set) var session: SSHTerminalSession?
	private weak var coordinator: TerminalCoordinator?
	private let make: () -> SSHTerminalSession

	public init(makeSession: @escaping () -> SSHTerminalSession) {
		self.make = makeSession
	}

	func bindTerminal(_ c: TerminalCoordinator) { self.coordinator = c }

	public func start() {
		let s = make()
		s.onStateChange = { [weak self] st in
			Task { @MainActor in self?.state = st }
		}
		s.onOutput = { [weak self] bytes in
			Task { @MainActor in self?.coordinator?.feed(bytes) }
		}
		session = s
		Task { await s.connect() }
	}

	public func tapKey(_ key: TerminalKeyBar.Key) {
		let bytes = keyBar.bytes(for: key)
		guard !bytes.isEmpty else { return }
		Task { await session?.send(bytes) }
	}

	public func disconnect() {
		Task { await session?.disconnect() }
	}
}

public struct MobileTerminalSessionView: View {
	@StateObject private var model: TerminalScreenModel
	@Environment(\.dismiss) private var dismiss
	let title: String

	public init(title: String, makeSession: @escaping () -> SSHTerminalSession) {
		self.title = title
		_model = StateObject(wrappedValue: TerminalScreenModel(makeSession: makeSession))
	}

	public var body: some View {
		VStack(spacing: 0) {
			SwiftTermBridge(model: model)
				.ignoresSafeArea(.container, edges: .bottom)
			TerminalKeyBarView(model: model)
		}
		.navigationTitle(title)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button("Disconnect", role: .destructive) {
					model.disconnect()
					dismiss()
				}
			}
		}
		.overlay { connectionOverlay }
		.onAppear { model.start() }
	}

	@ViewBuilder private var connectionOverlay: some View {
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
}
#endif
