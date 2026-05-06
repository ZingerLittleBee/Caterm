import SnippetStore
import SnippetSyncClient
import SwiftUI

struct SnippetManagerSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var store: SnippetStore
	@EnvironmentObject var sync: SnippetSyncStore

	@State private var query: String = ""
	@State private var selectedID: UUID?
	@State private var editing: Snippet?
	@State private var creating: Bool = false

	private var results: [Snippet] {
		store.search(query).sorted(by: { $0.updatedAt > $1.updatedAt })
	}

	private var selectedSnippet: Snippet? {
		guard let id = selectedID else { return nil }
		return results.first { $0.id == id }
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				TextField("Search…", text: $query)
					.textFieldStyle(.roundedBorder)
				Button(action: { creating = true }) { Image(systemName: "plus") }
				Button("Done") { dismiss() }
			}
			.padding(8)

			Divider()

			HSplitView {
				List(results, selection: $selectedID) { s in
					SnippetRowView(
						snippet: s,
						onEdit: { editing = s },
						onDelete: { delete(s) },
						onCopy: { copy(s.content) }
					)
					.tag(s.id)
				}
				.listStyle(.plain)
				.frame(minWidth: 240)

				if let s = selectedSnippet {
					SnippetDetailView(snippet: s,
					                  onEdit: { editing = s },
					                  onDelete: { delete(s) })
				} else {
					VStack {
						Text("Select a snippet").foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}

			Divider()
			Text("⚠ Snippets travel through CloudKit. Do not store passwords or other secrets here.")
				.font(.caption).foregroundColor(.secondary)
				.padding(6)
		}
		.frame(minWidth: 720, minHeight: 480)
		.sheet(isPresented: $creating) {
			SnippetEditorSheet(mode: .create)
				.environmentObject(store)
				.environmentObject(sync)
		}
		.sheet(item: $editing) { s in
			SnippetEditorSheet(mode: .edit(s))
				.environmentObject(store)
				.environmentObject(sync)
		}
	}

	private func delete(_ s: Snippet) {
		do {
			try store.delete(id: s.id)
			sync.scheduleSyncPass(debounceMs: 0)
		} catch {
			NSLog("[SnippetManagerSheet] delete failed: \(error.localizedDescription)")
		}
	}

	private func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}

private struct SnippetDetailView: View {
	let snippet: Snippet
	let onEdit: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(snippet.name).font(.title2)
			ScrollView {
				Text(snippet.content)
					.font(.system(.body, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
			}
			.background(Color.secondary.opacity(0.05))
			HStack {
				Spacer()
				Button("Edit", action: onEdit)
				Button("Delete", role: .destructive, action: onDelete)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
