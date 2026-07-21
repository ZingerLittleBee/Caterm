import SnippetStore
import SnippetSyncClient
import SwiftUI

struct SnippetEditorSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var store: SnippetStore
	@EnvironmentObject var sync: SnippetSyncStore

	enum Mode {
		case create
		case edit(Snippet)
	}

	let mode: Mode

	@State private var name: String = ""
	@State private var content: String = ""

	private var canSave: Bool {
		!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(titleLabel).font(.headline)
			TextField("Name", text: $name)
				.textFieldStyle(.roundedBorder)
			TextEditor(text: $content)
				.font(.system(.body, design: .monospaced))
				.frame(minHeight: 240)
				.border(Color.secondary.opacity(0.3))
			Text("⚠ Snippets travel through CloudKit. Do not store passwords or other secrets here.")
				.font(.caption).foregroundColor(.secondary)
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(!canSave)
			}
		}
		.padding()
		.frame(minWidth: 520, minHeight: 360)
		.onAppear(perform: loadInitial)
	}

	private var titleLabel: String {
		switch mode {
		case .create: return "New Snippet"
		case .edit:   return "Edit Snippet"
		}
	}

	private func loadInitial() {
		if case .edit(let s) = mode {
			name = s.name
			content = s.content
		}
	}

	private func save() {
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedContent = content
		do {
			switch mode {
			case .create:
				let s = Snippet(
					id: UUID(), name: trimmedName, content: trimmedContent,
					createdAt: Date(), updatedAt: Date()
				)
				try store.upsert(s)
			case .edit(let original):
				var copy = original
				copy.name = trimmedName
				copy.content = trimmedContent
				try store.upsert(copy)
			}
			sync.scheduleSyncPass(debounceMs: 500)
			dismiss()
		} catch {
			NSLog("[SnippetEditorSheet] save failed: \(error.localizedDescription)")
		}
	}
}
