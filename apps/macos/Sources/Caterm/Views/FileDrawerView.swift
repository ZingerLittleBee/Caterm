import SwiftUI
import FileTransferStore
import SSHCommandBuilder

@MainActor
struct FileDrawerView: View {
	let host: SSHHost?
	let fs: RemoteFileSystem?
	@State private var path: String = "~"
	@State private var entries: [RemoteEntry] = []
	@State private var selection: RemoteEntry.ID?
	@State private var error: String?

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(path).font(.system(.body, design: .monospaced))
				Spacer()
				Button { Task { await refresh() } } label: {
					Image(systemName: "arrow.clockwise")
				}.buttonStyle(.borderless)
			}.padding(8)

			Divider()

			if host == nil {
				ContentUnavailableView(
					"Not connected",
					systemImage: "wifi.slash",
					description: Text("Connect to a host to browse files.")
				)
			} else if let err = error {
				ContentUnavailableView(
					"Error",
					systemImage: "exclamationmark.triangle",
					description: Text(err)
				)
			} else {
				RemoteFileListView(entries: entries, selection: $selection) { entry in
					if entry.isDirectory {
						path = (path as NSString).appendingPathComponent(entry.name)
						Task { await refresh() }
					}
				}
			}
		}
		.frame(minWidth: 240)
		.task(id: host?.id) { await refresh() }
	}

	private func refresh() async {
		guard let fs else { return }
		do {
			self.entries = try await fs.list(path)
			self.error = nil
		} catch RemoteFileSystemError.sessionGone {
			self.error = "Reconnect host to browse files"
		} catch {
			self.error = "\(error)"
		}
	}
}
