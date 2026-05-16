import FileTransferStore
import SwiftUI

public struct MobileFileBrowserView: View {
	@State private var model = MobileFileBrowserModel()
	let entries: [RemoteEntry]
	let transfers: [TransferTask]

	public init(entries: [RemoteEntry] = [], transfers: [TransferTask] = []) {
		self.entries = entries
		self.transfers = transfers
	}

	public var body: some View {
		List {
			Section {
				if model.path != "~", model.path != "/" {
					Button {
						model.goUp()
					} label: {
						Label("Parent Folder", systemImage: "arrow.up")
					}
				}

				if entries.isEmpty {
					ContentUnavailableView("No Files", systemImage: "folder")
						.listRowSeparator(.hidden)
				} else {
					ForEach(entries) { entry in
						Button {
							model.activate(entry)
						} label: {
							MobileRemoteEntryRow(entry: entry)
						}
						.contextMenu {
							Button {
								model.requestRename(entry)
							} label: {
								Label("Rename", systemImage: "pencil")
							}
							Button(role: .destructive) {
								model.requestDelete(entry)
							} label: {
								Label("Delete", systemImage: "trash")
							}
						}
					}
				}
			}

			if !transfers.isEmpty {
				Section("Transfers") {
					ForEach(transfers) { task in
						MobileTransferRow(task: task)
					}
				}
			}
		}
		.navigationTitle(model.path)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					model.presentation = nil
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.accessibilityLabel("Refresh")

				Menu {
					Button {
						model.presentation = .rename(path: model.path.appendingNewFolderName, currentName: "New Folder")
					} label: {
						Label("New Folder", systemImage: "folder.badge.plus")
					}
					Button {
						model.presentation = .download(path: model.path)
					} label: {
						Label("Download", systemImage: "square.and.arrow.down")
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.accessibilityLabel("File Actions")
			}
		}
		.confirmationDialog(
			"File Action",
			isPresented: Binding(
				get: { model.presentation != nil },
				set: { if !$0 { model.presentation = nil } }
			),
			presenting: model.presentation
		) { presentation in
			switch presentation {
			case .download:
				Button("Download") { model.presentation = nil }
			case .confirmDelete:
				Button("Delete", role: .destructive) { model.presentation = nil }
			case .rename:
				Button("Rename") { model.presentation = nil }
			}
			Button("Cancel", role: .cancel) { model.presentation = nil }
		} message: { presentation in
			Text(message(for: presentation))
		}
	}

	private func message(for presentation: MobileFileBrowserPresentation) -> String {
		switch presentation {
		case .download(let path):
			"Download \(path) when mobile file export is wired."
		case .confirmDelete(let path, let isDirectory):
			"Delete \(isDirectory ? "folder" : "file") \(path)?"
		case .rename(let path, _):
			"Rename \(path) when mobile file operations are wired."
		}
	}
}

private struct MobileRemoteEntryRow: View {
	let entry: RemoteEntry

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: entry.isDirectory ? "folder" : "doc")
				.foregroundStyle(entry.isDirectory ? .blue : .secondary)
			VStack(alignment: .leading, spacing: 4) {
				Text(entry.name)
					.font(.headline)
				if !entry.isDirectory {
					Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			if entry.isDirectory {
				Image(systemName: "chevron.right")
					.font(.caption)
					.foregroundStyle(.tertiary)
			}
		}
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
	}
}

private struct MobileTransferRow: View {
	let task: TransferTask

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(title, systemImage: task.kind == .upload ? "arrow.up.doc" : "arrow.down.doc")
			Text(task.destination)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.accessibilityElement(children: .combine)
	}

	private var title: String {
		switch task.status {
		case .pending: "Pending"
		case .running: "Running"
		case .completed: "Completed"
		case .failed: "Failed"
		case .cancelled: "Cancelled"
		}
	}
}

private extension String {
	var appendingNewFolderName: String {
		switch self {
		case "~":
			"~/New Folder"
		case "/":
			"/New Folder"
		default:
			hasSuffix("/") ? "\(self)New Folder" : "\(self)/New Folder"
		}
	}
}
