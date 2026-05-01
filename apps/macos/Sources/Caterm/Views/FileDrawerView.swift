import AppKit
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
	@State private var sheetMode: SheetMode?

	private enum SheetMode: Identifiable {
		case rename(RemoteEntry)
		case mkdir

		var id: String {
			switch self {
			case .rename(let entry): return "rename:\(entry.id)"
			case .mkdir: return "mkdir"
			}
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(path).font(.system(.body, design: .monospaced))
				Spacer()
				Button { sheetMode = .mkdir } label: {
					Image(systemName: "folder.badge.plus")
				}
				.buttonStyle(.borderless)
				.help("New Folder")
				.disabled(host == nil || fs == nil)
				Button { Task { await refresh() } } label: {
					Image(systemName: "arrow.clockwise")
				}.buttonStyle(.borderless)
			}.padding(8)

			Divider()

			// Each branch is wrapped to fill the drawer's available space. Without
			// this, ContentUnavailableView's content-driven intrinsic width (much
			// larger than the path bar's) propagates up the VStack and pushes the
			// HSplitView to give the drawer more horizontal space, squashing the
			// terminal on the other side. List (used when entries exist) doesn't
			// have that issue, which is why the squashing only showed in the empty
			// / error / not-connected states.
			Group {
				if host == nil {
					ContentUnavailableView(
						"Not connected",
						systemImage: "wifi.slash",
						description: Text("Connect to a host to browse files.")
					)
				} else if let err = error {
					if err == "Reconnect host to browse files" {
						ContentUnavailableView {
							Label("Reconnect host", systemImage: "arrow.clockwise")
						} description: {
							Text("Master connection expired. Reconnect the terminal session, then click Try Again.")
						} actions: {
							Button("Try Again") { Task { await refresh() } }
						}
					} else {
						ContentUnavailableView(
							"Error",
							systemImage: "exclamationmark.triangle",
							description: Text(err)
						)
					}
				} else if entries.isEmpty {
					ContentUnavailableView(
						"Empty folder",
						systemImage: "folder"
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
						},
						onDownload: { entry in handleDownload(entry) },
						onRename: { entry in sheetMode = .rename(entry) },
						onDelete: { entry in handleDelete(entry) },
						onCopyPath: { entry in handleCopyPath(entry) }
					)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)

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
		.sheet(item: $sheetMode) { mode in
			switch mode {
			case .rename(let entry):
				SimpleTextSheet(
					title: "Rename",
					prompt: "New name",
					initialValue: entry.name,
					submitLabel: "Rename",
					onSubmit: { newName in
						sheetMode = nil
						handleRename(entry, newName: newName)
					},
					onCancel: { sheetMode = nil }
				)
			case .mkdir:
				SimpleTextSheet(
					title: "New Folder",
					prompt: "Folder name",
					initialValue: "",
					submitLabel: "Create",
					onSubmit: { name in
						sheetMode = nil
						handleMkdir(name: name)
					},
					onCancel: { sheetMode = nil }
				)
			}
		}
	}

	private func handleDrop(urls: [URL], remoteDir: String) {
		guard let host, let store = fileTransferStore else { return }
		_ = store.enqueueUpload(localPaths: urls, remoteDir: remoteDir, host: host)
		Task { await refresh() }
	}

	private func handleDownload(_ entry: RemoteEntry) {
		guard let host, let store = fileTransferStore else { return }
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Download"
		panel.message = "Choose a destination folder"
		guard panel.runModal() == .OK, let localDir = panel.url else { return }
		let remotePath = (path as NSString).appendingPathComponent(entry.name)
		_ = store.enqueueDownload(remotePaths: [remotePath], localDir: localDir, host: host)
	}

	private func handleRename(_ entry: RemoteEntry, newName: String) {
		guard let fs else { return }
		let trimmed = newName.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, trimmed != entry.name else { return }
		let from = (path as NSString).appendingPathComponent(entry.name)
		let to = (path as NSString).appendingPathComponent(trimmed)
		Task {
			do {
				try await fs.rename(from: from, to: to)
				await refresh()
			} catch {
				self.error = "\(error)"
			}
		}
	}

	private func handleDelete(_ entry: RemoteEntry) {
		guard let fs else { return }
		let target = (path as NSString).appendingPathComponent(entry.name)
		let isDir = entry.isDirectory
		Task {
			do {
				try await fs.remove(target, isDirectory: isDir)
				await refresh()
			} catch {
				self.error = "\(error)"
			}
		}
	}

	private func handleCopyPath(_ entry: RemoteEntry) {
		let full = (path as NSString).appendingPathComponent(entry.name)
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(full, forType: .string)
	}

	private func handleMkdir(name: String) {
		guard let fs else { return }
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let target = (path as NSString).appendingPathComponent(trimmed)
		Task {
			do {
				try await fs.mkdir(target)
				await refresh()
			} catch {
				self.error = "\(error)"
			}
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
