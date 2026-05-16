import SnippetSyncClient
import SwiftUI

public struct MobileSnippetsView: View {
	@Binding private var snippets: [Snippet]
	@State private var searchText = ""
	@State private var showingEditor = false
	@State private var editingSnippet: Snippet?

	public init(snippets: Binding<[Snippet]>) {
		_snippets = snippets
	}

	public var body: some View {
		List {
			if filteredSnippets.isEmpty {
				ContentUnavailableView("No Snippets", systemImage: "text.cursor")
					.listRowSeparator(.hidden)
			} else {
				ForEach(filteredSnippets) { snippet in
					NavigationLink(value: MobileSnippetRoute.detail(snippet.id)) {
						VStack(alignment: .leading, spacing: 4) {
							Text(snippet.name)
								.font(.headline)
							Text(snippet.content)
								.font(.subheadline)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}
						.accessibilityElement(children: .combine)
					}
					.swipeActions {
						Button(role: .destructive) {
							snippets.removeAll { $0.id == snippet.id }
						} label: {
							Label("Delete", systemImage: "trash")
						}
					}
				}
			}
		}
		.navigationTitle("Snippets")
		.searchable(text: $searchText, prompt: "Search snippets")
		.navigationDestination(for: MobileSnippetRoute.self) { route in
			destination(for: route)
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					editingSnippet = nil
					showingEditor = true
				} label: {
					Image(systemName: "plus")
				}
				.accessibilityLabel("Add Snippet")
			}
		}
		.sheet(isPresented: $showingEditor) {
			NavigationStack {
				MobileSnippetEditorView(snippet: editingSnippet) { snippet in
					if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
						snippets[index] = snippet
					} else {
						snippets.append(snippet)
					}
					showingEditor = false
				}
			}
		}
	}

	private var filteredSnippets: [Snippet] {
		let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return snippets }
		let needle = trimmed.lowercased()
		return snippets.filter {
			$0.name.lowercased().contains(needle)
				|| $0.content.lowercased().contains(needle)
		}
	}

	@ViewBuilder
	private func destination(for route: MobileSnippetRoute) -> some View {
		switch route {
		case .detail(let id):
			if let snippet = snippets.first(where: { $0.id == id }) {
				MobileSnippetDetailView(snippet: snippet) {
					editingSnippet = snippet
					showingEditor = true
				}
			} else {
				ContentUnavailableView("Snippet Not Found", systemImage: "text.cursor")
			}
		case .edit(let id):
			if let snippet = snippets.first(where: { $0.id == id }) {
				MobileSnippetEditorView(snippet: snippet) { updated in
					if let index = snippets.firstIndex(where: { $0.id == id }) {
						snippets[index] = updated
					}
				}
			} else {
				ContentUnavailableView("Snippet Not Found", systemImage: "text.cursor")
			}
		case .terminalPlaceholder(let id):
			MobileTerminalPlaceholderView(
				host: nil,
				snippet: snippets.first(where: { $0.id == id })?.name
			)
		case .hostTerminal:
			MobileTerminalPlaceholderView(host: nil, snippet: nil)
		}
	}
}

private struct MobileSnippetDetailView: View {
	let snippet: Snippet
	let onEdit: () -> Void
	@State private var route: MobileSnippetRoute?

	var body: some View {
		List {
			Section {
				Text(snippet.content)
					.font(.body.monospaced())
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}

			Section {
				Button {
					route = MobileSnippetActions.runRoute(for: snippet, targetHostId: nil)
				} label: {
					Label("Run", systemImage: "play")
				}
				.disabled(!MobileSnippetActions.canCopy(snippet))

				Button(action: onEdit) {
					Label("Edit", systemImage: "pencil")
				}
			}
		}
		.navigationTitle(snippet.name)
		.navigationDestination(item: $route) { route in
			switch route {
			case .terminalPlaceholder:
				MobileTerminalPlaceholderView(host: nil, snippet: snippet.name)
			case .hostTerminal:
				MobileTerminalPlaceholderView(host: nil, snippet: snippet.name)
			case .detail, .edit:
				EmptyView()
			}
		}
	}
}

private struct MobileSnippetEditorView: View {
	let snippet: Snippet?
	let onSave: (Snippet) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var name: String
	@State private var content: String

	init(snippet: Snippet?, onSave: @escaping (Snippet) -> Void) {
		self.snippet = snippet
		self.onSave = onSave
		_name = State(initialValue: snippet?.name ?? "")
		_content = State(initialValue: snippet?.content ?? "")
	}

	var body: some View {
		Form {
			Section("Snippet") {
				TextField("Name", text: $name)
				TextField("Command", text: $content, axis: .vertical)
					.lineLimit(4...12)
					.font(.body.monospaced())
			}
		}
		.navigationTitle(snippet == nil ? "Add Snippet" : "Edit Snippet")
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel") { dismiss() }
			}
			ToolbarItem(placement: .confirmationAction) {
				Button("Save", action: save)
					.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
	}

	private func save() {
		let now = Date()
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let updated = Snippet(
			id: snippet?.id ?? UUID(),
			name: trimmedName,
			content: content,
			placeholders: snippet?.placeholders,
			createdAt: snippet?.createdAt ?? now,
			updatedAt: now,
			serverId: snippet?.serverId,
			revision: snippet?.revision ?? 0,
			metadataUpdatedAt: snippet?.metadataUpdatedAt
		)
		onSave(updated)
		dismiss()
	}
}
