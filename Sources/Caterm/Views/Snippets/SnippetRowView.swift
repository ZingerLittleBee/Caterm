import SnippetSyncClient
import SwiftUI

struct SnippetRowView: View {
	let snippet: Snippet
	let onEdit: () -> Void
	let onDelete: () -> Void
	let onCopy: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(snippet.name).font(.body)
				Text(firstContentLine)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			Spacer()
			Menu {
				Button("Edit", action: onEdit)
				Button("Copy content", action: onCopy)
				Divider()
				Button("Delete", role: .destructive, action: onDelete)
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
		}
		.padding(.vertical, 4)
		.contentShape(Rectangle())
	}

	private var firstContentLine: String {
		let firstLine = snippet.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
		return firstLine.isEmpty ? " " : firstLine
	}
}
