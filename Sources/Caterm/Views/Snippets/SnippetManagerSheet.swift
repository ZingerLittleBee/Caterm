import SnippetStore
import SnippetSyncClient
import SwiftUI

/// Manager sheet — master/detail snippet browser. Built on `NavigationSplitView`
/// so the split chrome, toolbar, and `.searchable` field all share the
/// system's sheet styling. Replaces an earlier hand-rolled `HSplitView` +
/// `.roundedBorder` `TextField` layout that had two visual bugs:
/// (a) the detail pane could be dragged to a width too narrow to hold its
///     own buttons, and
/// (b) the rounded-bezel search field's corner radius didn't match the sheet's.
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
		NavigationSplitView {
			List(results, selection: $selectedID) { s in
				SnippetRowView(
					snippet: s,
					onEdit: { editing = s },
					onDelete: { delete(s) },
					onCopy: { copy(s.content) }
				)
				.tag(s.id)
			}
			.listStyle(.inset)
			.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 480)
		} detail: {
			Group {
				if let s = selectedSnippet {
					SnippetDetailView(
						snippet: s,
						onEdit: { editing = s },
						onDelete: { delete(s) }
					)
				} else {
					ContentUnavailableView(
						"No Snippet Selected",
						systemImage: "text.cursor",
						description: Text("Pick a snippet on the left to preview or edit it.")
					)
				}
			}
			.navigationSplitViewColumnWidth(min: 360, ideal: 520)
		}
		.searchable(text: $query, prompt: "Search snippets")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					creating = true
				} label: {
					Label("New Snippet", systemImage: "plus")
				}
				.help("New snippet")
			}
			ToolbarItem(placement: .confirmationAction) {
				Button("Done") { dismiss() }
			}
		}
		.frame(minWidth: 780, minHeight: 500)
		.safeAreaInset(edge: .bottom) {
			HStack(spacing: 6) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.yellow)
				Text("Snippets travel through CloudKit. Do not store passwords or other secrets here.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
			.padding(.horizontal, 12)
			.background(.bar)
		}
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
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text(snippet.name)
					.font(.title2.weight(.semibold))
					.textSelection(.enabled)
				Text("Updated \(snippet.updatedAt.formatted(.relative(presentation: .named)))")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			ScrollView {
				Text(snippet.content)
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(12)
			}
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Color(nsColor: .textBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.stroke(Color.secondary.opacity(0.2), lineWidth: 1)
			)

			HStack {
				Spacer()
				Button("Edit", action: onEdit)
					.keyboardShortcut("e", modifiers: .command)
				Button("Delete", role: .destructive, action: onDelete)
			}
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}
