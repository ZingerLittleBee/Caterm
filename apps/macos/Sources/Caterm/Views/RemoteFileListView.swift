import SwiftUI
import FileTransferStore

struct RemoteFileListView: View {
	let entries: [RemoteEntry]
	@Binding var selection: RemoteEntry.ID?
	let onActivate: (RemoteEntry) -> Void

	var body: some View {
		List(entries, selection: $selection) { entry in
			HStack {
				Image(systemName: entry.isDirectory ? "folder" : "doc")
				Text(entry.name)
				Spacer()
				if !entry.isDirectory {
					Text(byteString(entry.size)).foregroundStyle(.secondary)
				}
			}
			.contentShape(Rectangle())
			.onTapGesture(count: 2) { onActivate(entry) }
		}
	}

	private func byteString(_ n: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
	}
}
