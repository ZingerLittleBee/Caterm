import SnippetStore
import SnippetSyncClient
import SwiftUI

// MARK: - View Model

@MainActor
public final class SnippetPaletteViewModel: ObservableObject {
	public let store: SnippetStore
	public let capturedSurface: (any SnippetDispatchTarget)?
	@Published public var query: String = ""

	public init(store: SnippetStore, capturedSurface: (any SnippetDispatchTarget)?) {
		self.store = store
		self.capturedSurface = capturedSurface
	}

	public var results: [Snippet] {
		store.search(query)
			.sorted { $0.updatedAt > $1.updatedAt }
	}

	public var canDispatch: Bool { capturedSurface != nil }

	public func paste(_ s: Snippet) {
		capturedSurface?.paste(s.content)
	}

	public func run(_ s: Snippet) {
		capturedSurface?.run(s.content)
	}
}

// MARK: - View

struct SnippetPalette: View {
	@StateObject private var vm: SnippetPaletteViewModel
	@FocusState private var searchFocused: Bool
	@State private var selectedID: UUID?
	let sync: SnippetSyncStore
	let onClose: () -> Void
	let onCreate: () -> Void

	init(
		store: SnippetStore,
		sync: SnippetSyncStore,
		capturedSurface: (any SnippetDispatchTarget)?,
		onClose: @escaping () -> Void,
		onCreate: @escaping () -> Void
	) {
		_vm = StateObject(wrappedValue: SnippetPaletteViewModel(
			store: store, capturedSurface: capturedSurface
		))
		self.sync = sync
		self.onClose = onClose
		self.onCreate = onCreate
	}

	var body: some View {
		VStack(spacing: 0) {
			if !vm.canDispatch {
				Text("No active terminal — connect to a host first")
					.font(.caption)
					.foregroundColor(.secondary)
					.padding(8)
			}
			TextField("Search snippets…", text: $vm.query)
				.textFieldStyle(.plain)
				.padding(8)
				.focused($searchFocused)

			Divider()

			if vm.results.isEmpty {
				VStack(spacing: 8) {
					Text("No snippets yet")
					Button("Create your first snippet (⌘⇧S)", action: onCreate)
				}
				.padding()
			} else {
				List(vm.results, selection: $selectedID) { s in
					SnippetRowView(
						snippet: s,
						onEdit: { openManagerForEdit() },
						onDelete: { deleteSnippet(s) },
						onCopy: { copyToClipboard(s) }
					)
					.tag(s.id)
				}
				.listStyle(.plain)
			}

			Divider()
			HStack {
				Text(
					vm.canDispatch
						? "Enter — paste · ⌘+Enter — run · Esc — close"
						: "Connect a host to enable dispatch"
				)
				.font(.caption)
				.foregroundColor(.secondary)
				Spacer()
			}
			.padding(8)
		}
		.frame(width: 520, height: 380)
		.onAppear { searchFocused = true }
		.onKeyPress(.escape) { onClose(); return .handled }
		.onKeyPress(.return) { handleEnter(); return .handled }
		// Hidden buttons provide ⌘+Enter keyboard dispatch without
		// requiring the `onKeyPress(_:modifiers:)` overload.
		.background {
			Button("") { handleCmdEnter() }
				.keyboardShortcut(.return, modifiers: .command)
				.hidden()
		}
	}

	private func openManagerForEdit() {
		NotificationCenter.default.post(name: .catermOpenSnippetManager, object: nil)
		onClose()
	}

	private func deleteSnippet(_ s: Snippet) {
		try? vm.store.delete(id: s.id)
		sync.scheduleSyncPass(debounceMs: 0)
	}

	private func selected() -> Snippet? {
		let id = selectedID ?? vm.results.first?.id
		guard let id else { return nil }
		return vm.results.first { $0.id == id }
	}

	private func handleEnter() {
		guard let s = selected(), vm.canDispatch else { return }
		vm.paste(s)
		onClose()
	}

	private func handleCmdEnter() {
		guard let s = selected(), vm.canDispatch else { return }
		vm.run(s)
		onClose()
	}

	private func copyToClipboard(_ s: Snippet) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(s.content, forType: .string)
	}
}
