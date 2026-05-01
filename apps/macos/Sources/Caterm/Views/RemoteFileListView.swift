import SwiftUI
import UniformTypeIdentifiers
import FileTransferStore

struct RemoteFileListView: View {
	let entries: [RemoteEntry]
	@Binding var selection: RemoteEntry.ID?
	let onActivate: (RemoteEntry) -> Void
	var onDropOnFolder: (RemoteEntry, [URL]) -> Void = { _, _ in }
	var onDownload: (RemoteEntry) -> Void = { _ in }
	var onRename: (RemoteEntry) -> Void = { _ in }
	var onDelete: (RemoteEntry) -> Void = { _ in }
	var onCopyPath: (RemoteEntry) -> Void = { _ in }

	var body: some View {
		List(entries, selection: $selection) { entry in
			HStack(spacing: 6) {
				if entry.isDirectory {
					Image(systemName: "folder.fill")
						.foregroundStyle(.tint)
				} else {
					Image(systemName: "doc")
						.foregroundStyle(.secondary)
				}
				Text(entry.name)
					.lineLimit(1)
					.truncationMode(.middle)
					.frame(maxWidth: .infinity, alignment: .leading)
				if !entry.isDirectory {
					Text(byteString(entry.size))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.fixedSize(horizontal: true, vertical: false)
				}
			}
			// macOS List adds a trailing safe-area for the overlay scroller.
			// Without explicit trailing room, the size column gets clipped
			// even though Spacer/maxWidth layout says there's space.
			.padding(.trailing, 16)
			.contentShape(Rectangle())
			.onTapGesture(count: 2) { onActivate(entry) }
			.modifier(FolderDropModifier(entry: entry, onDropOnFolder: onDropOnFolder))
			.contextMenu {
				if !entry.isDirectory {
					Button("Download…") { onDownload(entry) }
				}
				Button("Rename…") { onRename(entry) }
				Button("Delete", role: .destructive) { onDelete(entry) }
				Divider()
				Button("Copy Path") { onCopyPath(entry) }
			}
		}
	}

	private func byteString(_ n: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
	}
}

/// Attaches a `.onDrop` only when the row represents a directory. Wrapped in a
/// `ViewModifier` to keep the row body declarative.
private struct FolderDropModifier: ViewModifier {
	let entry: RemoteEntry
	let onDropOnFolder: (RemoteEntry, [URL]) -> Void

	func body(content: Content) -> some View {
		if entry.isDirectory {
			content.onDrop(of: [.fileURL], isTargeted: nil) { providers in
				Task {
					let urls = await loadURLs(from: providers)
					if !urls.isEmpty {
						await MainActor.run { onDropOnFolder(entry, urls) }
					}
				}
				return true
			}
		} else {
			content
		}
	}

	private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
		await withTaskGroup(of: URL?.self) { group in
			for provider in providers where provider.canLoadObject(ofClass: URL.self) {
				group.addTask {
					await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
						_ = provider.loadObject(ofClass: URL.self) { url, _ in
							cont.resume(returning: url)
						}
					}
				}
			}
			var out: [URL] = []
			for await u in group { if let u { out.append(u) } }
			return out
		}
	}
}
