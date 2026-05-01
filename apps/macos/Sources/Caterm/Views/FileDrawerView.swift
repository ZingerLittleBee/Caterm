import SwiftUI
import UniformTypeIdentifiers
import FileTransferStore
import SSHCommandBuilder

@MainActor
struct FileDrawerView: View {
	let host: SSHHost?
	let fs: RemoteFileSystem?
	let fileTransferStore: FileTransferStore?
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
				RemoteFileListView(
					entries: entries,
					selection: $selection,
					onActivate: { entry in
						if entry.isDirectory {
							path = (path as NSString).appendingPathComponent(entry.name)
							Task { await refresh() }
						}
					},
					onDropOnFolder: { entry, urls in
						let folderPath = (path as NSString).appendingPathComponent(entry.name)
						handleDrop(urls: urls, remoteDir: folderPath)
					}
				)
			}

			if let fts = fileTransferStore {
				Divider()
				TransferQueueView(store: fts)
					.background(.thickMaterial)
			}
		}
		.frame(minWidth: 240)
		.task(id: host?.id) { await refresh() }
		.onDrop(of: [.fileURL], isTargeted: nil) { providers in
			guard host != nil, fileTransferStore != nil else { return false }
			Task {
				let urls = await loadURLs(from: providers)
				if !urls.isEmpty {
					handleDrop(urls: urls, remoteDir: path)
				}
			}
			return true
		}
	}

	private func handleDrop(urls: [URL], remoteDir: String) {
		guard let host, let store = fileTransferStore else { return }
		_ = store.enqueueUpload(localPaths: urls, remoteDir: remoteDir, host: host)
		Task { await refresh() }
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
