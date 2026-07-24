import SnippetSyncClient
import SwiftUI

@MainActor
struct MobileSnippetMutationAction {
	let upsert: @MainActor (Snippet) throws -> Void
	let delete: @MainActor (UUID) throws -> Void
	let move: @MainActor (IndexSet, Int) throws -> Void
}

private struct MobileSnippetMutationActionKey: EnvironmentKey {
	static let defaultValue: MobileSnippetMutationAction? = nil
}

extension EnvironmentValues {
	var mobileSnippetMutation: MobileSnippetMutationAction? {
		get { self[MobileSnippetMutationActionKey.self] }
		set { self[MobileSnippetMutationActionKey.self] = newValue }
	}
}

public struct MobileSnippetsView: View {
	@Binding private var snippets: [Snippet]
	@State private var searchText = ""
	@State private var showingEditor = false
	@State private var editingSnippet: Snippet?
	@State private var errorMessage: String?
	@Environment(\.mobileSnippetMutation) private var mutation

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
							delete(snippet.id)
						} label: {
							Label("Delete", systemImage: "trash")
						}
					}
				}
				.onMove(perform: move)
			}
		}
		.navigationTitle("Snippets")
		.searchable(text: $searchText, prompt: "Search snippets")
		.navigationDestination(for: MobileSnippetRoute.self) { route in
			destination(for: route)
		}
		.toolbar {
			#if canImport(UIKit)
			if searchText.isEmpty, snippets.count > 1 {
				ToolbarItem(placement: .secondaryAction) {
					EditButton()
				}
			}
			#endif
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
					save(snippet)
				}
			}
		}
		.alert("Couldn’t Save Snippets", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("OK") { errorMessage = nil }
		} message: {
			if let errorMessage { Text(errorMessage) }
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
					save(updated)
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

	private func save(_ snippet: Snippet) {
		do {
			if let mutation {
				try mutation.upsert(snippet)
			} else if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
				snippets[index] = snippet
			} else {
				snippets.append(snippet)
			}
			showingEditor = false
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func delete(_ id: UUID) {
		do {
			if let mutation {
				try mutation.delete(id)
			} else {
				snippets.removeAll { $0.id == id }
			}
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func move(from source: IndexSet, to destination: Int) {
		guard searchText.isEmpty else { return }
		do {
			if let mutation {
				try mutation.move(source, destination)
			} else {
				var reordered = snippets
				let moved = source.map { reordered[$0] }
				for index in source.sorted(by: >) { reordered.remove(at: index) }
				let removedBefore = source.filter { $0 < destination }.count
				let insertion = min(destination - removedBefore, reordered.count)
				reordered.insert(contentsOf: moved, at: insertion)
				snippets = reordered
			}
		} catch {
			errorMessage = error.localizedDescription
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
