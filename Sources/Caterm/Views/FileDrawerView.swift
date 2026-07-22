import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FileTransferStore
import SessionStore
import SSHCommandBuilder
import WorkspaceCore

@MainActor
struct FileDrawerView: View {
	let paneID: PaneID
	let context: ActivePaneFileContext
	let host: SSHHost?
	let fs: RemoteFileSystem?
	let fileTransferStore: FileTransferStore?
	let currentContext: () -> ActivePaneFileContext
	@State private var path: String = "~"
	@State private var entries: [RemoteEntry] = []
	@State private var selection: RemoteEntry.ID?
	@State private var error: String?
	@State private var sheetMode: SheetMode?
	@State private var showBookmarks: Bool = false
	@State private var resultGate = FileDrawerResultGate()
	@EnvironmentObject private var bookmarkStore: RemoteBookmarkStore

	private enum SheetMode: Identifiable {
		case rename(RemoteEntry, FileDrawerTaskIdentity, String)
		case mkdir(FileDrawerTaskIdentity, String)

		var id: String {
			switch self {
			case .rename(let entry, _, _): return "rename:\(entry.id)"
			case .mkdir: return "mkdir"
			}
		}
	}

	private var taskIdentity: FileDrawerTaskIdentity {
		FileDrawerTaskIdentity(paneID: paneID, context: context)
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Button { goUp() } label: {
					Image(systemName: "chevron.left")
				}
				.buttonStyle(.borderless)
				.help("Up to parent folder")
				.disabled(!canGoUp)
				.keyboardShortcut(.upArrow, modifiers: [.command])

				Text(path)
					.font(.system(.body, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer(minLength: 8)
				if let host {
					Button { showBookmarks.toggle() } label: {
						Image(systemName: isCurrentPathBookmarked(hostId: host.id)
							  ? "bookmark.fill" : "bookmark")
					}
					.buttonStyle(.borderless)
					.help("Bookmarks")
					.popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
						RemoteBookmarkPopover(
							hostId: host.id,
							currentPath: path,
							onPick: { newPath in
								path = newPath
								Task { await refresh() }
							},
							isPresented: $showBookmarks
						)
						.environmentObject(bookmarkStore)
					}
				}
				Button { sheetMode = .mkdir(taskIdentity, path) } label: {
					Image(systemName: "folder.badge.plus")
				}
				.buttonStyle(.borderless)
				.help("New Folder")
				.disabled(host == nil || fs == nil)
				Button { Task { await refresh() } } label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.help("Refresh")
			}
			// Match the List's trailing inset so the refresh button doesn't
			// hide under the HSplitView resize handle.
			.padding(.leading, 8)
			.padding(.trailing, 12)
			.padding(.vertical, 8)

			Divider()

			// Each branch is wrapped to fill the drawer's available space. Without
			// this, ContentUnavailableView's content-driven intrinsic width (much
			// larger than the path bar's) propagates up the VStack and pushes the
			// HSplitView to give the drawer more horizontal space, squashing the
			// terminal on the other side. List (used when entries exist) doesn't
			// have that issue, which is why the squashing only showed in the empty
			// / error / not-connected states.
			Group {
				if case .unavailable(let unavailable) = context {
					ContentUnavailableView(
						unavailable.title,
						systemImage: "wifi.slash",
						description: Text(unavailable.message)
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
						onRename: { entry in
							sheetMode = .rename(entry, taskIdentity, path)
						},
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
		.task(id: taskIdentity) {
			resultGate.begin(taskIdentity)
			path = "~"
			entries = []
			selection = nil
			error = nil
			guard case .ready = context else { return }
			await refresh(expected: taskIdentity)
		}
		.onDrop(of: [.fileURL], isTargeted: nil) { providers in
			guard let host, let fileTransferStore,
			      case .ready(let target) = context else { return false }
			let expected = taskIdentity
			let remoteDir = path
			Task {
				let urls = await loadURLs(from: providers)
				guard !urls.isEmpty,
				      isCurrent(expected, target: target) else { return }
				_ = fileTransferStore.enqueueUpload(
					localPaths: urls,
					remoteDir: remoteDir,
					host: host
				)
				await refresh(expected: expected)
			}
			return true
		}
		.sheet(item: $sheetMode) { mode in
			switch mode {
			case .rename(let entry, let expected, let parent):
				SimpleTextSheet(
					title: "Rename",
					prompt: "New name",
					initialValue: entry.name,
					submitLabel: "Rename",
					onSubmit: { newName in
						sheetMode = nil
						handleRename(
							entry,
							newName: newName,
							expected: expected,
							parent: parent
						)
					},
					onCancel: { sheetMode = nil }
				)
			case .mkdir(let expected, let parent):
				SimpleTextSheet(
					title: "New Folder",
					prompt: "Folder name",
					initialValue: "",
					submitLabel: "Create",
					onSubmit: { name in
						sheetMode = nil
						handleMkdir(name: name, expected: expected, parent: parent)
					},
					onCancel: { sheetMode = nil }
				)
			}
		}
	}

	/// True when the current `path` is already saved as a bookmark for this
	/// host (using lexical-only normalization, same as the popover's dedup).
	private func isCurrentPathBookmarked(hostId: UUID) -> Bool {
		let key = normalizeRemotePath(path)
		return bookmarkStore.bookmarks(for: hostId)
			.contains { normalizeRemotePath($0.path) == key }
	}

	/// Whether the drawer is showing somewhere we can navigate up from.
	/// `~` and `/` are roots; everything else has a parent.
	private var canGoUp: Bool {
		path != "~" && path != "~/" && path != "/" && !path.isEmpty
	}

	private func goUp() {
		guard canGoUp else { return }
		let parent = (path as NSString).deletingLastPathComponent
		// `~/foo` → `~`; `/etc/foo` → `/etc`; `foo` → `""` → fall back to `~`.
		path = parent.isEmpty ? "~" : parent
		Task { await refresh() }
	}

	private func handleDrop(urls: [URL], remoteDir: String) {
		guard let host, let store = fileTransferStore,
		      case .ready(let target) = context else { return }
		let expected = taskIdentity
		guard isCurrent(expected, target: target) else { return }
		_ = store.enqueueUpload(localPaths: urls, remoteDir: remoteDir, host: host)
		Task { await refresh(expected: expected) }
	}

	private func handleDownload(_ entry: RemoteEntry) {
		guard let host, let store = fileTransferStore,
		      case .ready(let target) = context else { return }
		let expected = taskIdentity
		let parent = path
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Download"
		panel.message = "Choose a destination folder"
		guard panel.runModal() == .OK, let localDir = panel.url else { return }
		guard isCurrent(expected, target: target) else { return }
		let remotePath = (parent as NSString).appendingPathComponent(entry.name)
		_ = store.enqueueDownload(remotePaths: [remotePath], localDir: localDir, host: host)
	}

	private func handleRename(
		_ entry: RemoteEntry,
		newName: String,
		expected: FileDrawerTaskIdentity,
		parent: String
	) {
		guard let fs else { return }
		guard isCurrent(expected) else { return }
		let trimmed = newName.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, trimmed != entry.name else { return }
		let from = (parent as NSString).appendingPathComponent(entry.name)
		let to = (parent as NSString).appendingPathComponent(trimmed)
		Task {
			guard isCurrent(expected) else { return }
			do {
				try await fs.rename(from: from, to: to)
				await refresh(expected: expected)
			} catch {
				guard resultGate.accepts(expected) else { return }
				self.error = "\(error)"
			}
		}
	}

	private func handleDelete(_ entry: RemoteEntry) {
		guard let fs else { return }
		let expected = taskIdentity
		guard isCurrent(expected) else { return }
		let target = (path as NSString).appendingPathComponent(entry.name)
		let isDir = entry.isDirectory
		Task {
			guard isCurrent(expected) else { return }
			do {
				try await fs.remove(target, isDirectory: isDir)
				await refresh(expected: expected)
			} catch {
				guard resultGate.accepts(expected) else { return }
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

	private func handleMkdir(
		name: String,
		expected: FileDrawerTaskIdentity,
		parent: String
	) {
		guard let fs else { return }
		guard isCurrent(expected) else { return }
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let target = (parent as NSString).appendingPathComponent(trimmed)
		Task {
			guard isCurrent(expected) else { return }
			do {
				try await fs.mkdir(target)
				await refresh(expected: expected)
			} catch {
				guard resultGate.accepts(expected) else { return }
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

	private func refresh(expected: FileDrawerTaskIdentity? = nil) async {
		let expected = expected ?? taskIdentity
		guard let fs else { return }
		do {
			let entries = try await fs.list(path)
			guard resultGate.accepts(expected) else { return }
			self.entries = entries
			self.error = nil
		} catch RemoteFileError.sessionUnavailable {
			guard resultGate.accepts(expected) else { return }
			self.error = "Reconnect host to browse files"
		} catch {
			guard resultGate.accepts(expected) else { return }
			self.error = "\(error)"
		}
	}

	private func isCurrent(
		_ identity: FileDrawerTaskIdentity,
		target explicitTarget: ActivePaneFileTarget? = nil
	) -> Bool {
		guard resultGate.accepts(identity) else { return false }
		let target: ActivePaneFileTarget
		if let explicitTarget {
			target = explicitTarget
		} else if case .ready(let readyTarget) = identity.context {
			target = readyTarget
		} else {
			return false
		}
		return FileDrawerOperationAuthorization.permits(
			identity: identity,
			expectedTarget: target,
			gate: resultGate,
			currentContext: currentContext()
		)
	}
}

struct FileDrawerTaskIdentity: Hashable {
	let paneID: PaneID
	let context: ActivePaneFileContext
}

struct FileDrawerResultGate {
	private(set) var current: FileDrawerTaskIdentity?

	mutating func begin(_ identity: FileDrawerTaskIdentity) {
		current = identity
	}

	func accepts(_ identity: FileDrawerTaskIdentity) -> Bool {
		current == identity
	}
}

enum FileDrawerOperationAuthorization {
	static func permits(
		identity: FileDrawerTaskIdentity,
		expectedTarget: ActivePaneFileTarget,
		gate: FileDrawerResultGate,
		currentContext: ActivePaneFileContext
	) -> Bool {
		gate.accepts(identity) && currentContext == .ready(expectedTarget)
	}
}
