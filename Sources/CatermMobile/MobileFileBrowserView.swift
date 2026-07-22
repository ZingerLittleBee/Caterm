import FileTransferStore
import SSHCommandBuilder
import SwiftUI

public struct MobileFileBrowserView: View {
	let hosts: [SSHHost]
	let transfers: [TransferTask]
	@StateObject private var controller: MobileFileBrowserController
	@State private var prompt: MobileFilePrompt?
	@State private var nameInput = ""

	public init(
		hosts: [SSHHost] = [],
		clientFactory: MobileRemoteFileClientFactory = .unavailable,
		entries: [RemoteEntry] = [],
		transfers: [TransferTask] = []
	) {
		self.hosts = hosts
		self.transfers = transfers
		_controller = StateObject(wrappedValue: MobileFileBrowserController(
			factory: clientFactory,
			entries: entries
		))
	}

	public var body: some View {
		List {
			if hosts.isEmpty {
				ContentUnavailableView(
					"No Hosts",
					systemImage: "server.rack",
					description: Text("Add a Host before browsing remote files.")
				)
				.listRowSeparator(.hidden)
			} else {
				Section("Connection") {
					Picker("Host", selection: hostSelection) {
						ForEach(hosts) { host in
							Text(host.name).tag(Optional(host.id))
						}
					}
				}
				Section {
					browserContent
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
		.navigationTitle(controller.model.path)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Menu {
					Button {
						guard let host = selectedHost,
							let context = controller.actionContext(host: host) else { return }
						nameInput = ""
						prompt = .createFolder(context)
					} label: {
						Label("New Folder", systemImage: "folder.badge.plus")
					}
					.accessibilityLabel("New Folder in \(controller.model.path)")
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.accessibilityLabel("File Actions in \(controller.model.path)")
				.disabled(
					selectedHost == nil
						|| controller.state != .loaded
						|| controller.mutation != nil
				)
			}
			ToolbarItem(placement: .primaryAction) {
				Button {
					guard let host = selectedHost else { return }
					Task { await controller.refresh(host: host) }
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.accessibilityLabel("Refresh")
				.disabled(
					selectedHost == nil
						|| controller.state == .connecting
						|| controller.mutation != nil
				)
			}
		}
		.task(id: hosts.map(\.id)) {
			if let selectedHost {
				await controller.refresh(host: selectedHost)
			} else if let first = hosts.first {
				controller.select(host: first)
			}
		}
		.onDisappear { controller.disconnect() }
		.refreshable {
			guard let host = selectedHost else { return }
			await controller.refresh(host: host)
		}
		.alert(promptTitle, isPresented: promptIsPresented, presenting: prompt) { prompt in
			switch prompt {
			case .createFolder(let context):
				TextField("Folder Name", text: $nameInput)
				Button("Cancel", role: .cancel) {}
				Button("Create") { createFolder(context: context) }
			case .rename(let context, let entry):
				TextField("Name", text: $nameInput)
				Button("Cancel", role: .cancel) {}
				Button("Rename") { rename(entry, context: context) }
			case .delete(let context, let entry):
				Button("Cancel", role: .cancel) {}
				Button("Delete", role: .destructive) {
					delete(entry, context: context)
				}
			}
		} message: { prompt in
			Text(prompt.message)
		}
		.alert(
			controller.mutationFailure?.title ?? "File Action Failed",
			isPresented: mutationFailureIsPresented
		) {
			if let actionTitle = controller.mutationFailure?.recoveryActionTitle {
				Button(actionTitle) {
					guard let host = selectedHost else { return }
					Task { await controller.retryMutation(host: host) }
				}
			}
			Button("OK", role: .cancel) { controller.dismissMutationFailure() }
		} message: {
			if let failure = controller.mutationFailure {
				Text("\(failure.message)\n\n\(failure.recoverySuggestion)")
			}
		}
	}

	@ViewBuilder
	private var browserContent: some View {
		if let host = selectedHost {
			if let mutation = controller.mutation {
				HStack(spacing: 12) {
					ProgressView()
					Text(mutation.progressDescription)
				}
				.accessibilityElement(children: .combine)
			}
			if controller.model.path != "~", controller.model.path != "/" {
				Button {
					controller.goUp(host: host)
				} label: {
					Label("Parent Folder", systemImage: "arrow.up")
				}
			}

			switch controller.state {
			case .idle where controller.entries.isEmpty,
			     .connecting where controller.entries.isEmpty:
				HStack {
					ProgressView()
					Text("Connecting to \(host.name)…")
				}
				.accessibilityElement(children: .combine)
			case .permissionDenied(let message):
				failureView("Permission Denied", message: message, image: "lock.trianglebadge.exclamationmark", host: host)
			case .disconnected:
				failureView("Disconnected", message: "The SFTP connection closed.", image: "bolt.slash", host: host)
			case .trustFailure(let message):
				failureView("Host Identity Changed", message: message, image: "exclamationmark.shield", host: host)
			case .failed(let message):
				failureView("Couldn’t Browse Files", message: message, image: "exclamationmark.triangle", host: host)
			case .idle, .connecting, .loaded:
				if controller.state == .connecting {
					ProgressView("Refreshing…")
				}
				if controller.entries.isEmpty {
					ContentUnavailableView("Empty Folder", systemImage: "folder")
						.listRowSeparator(.hidden)
				} else {
					ForEach(controller.entries) { entry in
						entryRow(entry, host: host)
							.contentShape(Rectangle())
							.contextMenu {
								entryActions(entry)
							}
							.swipeActions(edge: .trailing, allowsFullSwipe: false) {
								if entry.type != .unknown {
									Button(role: .destructive) { requestDelete(entry) } label: {
										Label("Delete", systemImage: "trash")
									}
									.accessibilityLabel(deleteAccessibilityLabel(entry))
								}
								Button { requestRename(entry) } label: {
									Label("Rename", systemImage: "pencil")
								}
								.tint(.blue)
								.accessibilityLabel("Rename \(entry.name)")
							}
							.disabled(
								controller.state != .loaded || controller.mutation != nil
							)
					}
				}
			}
		}
	}

	@ViewBuilder
	private func entryRow(_ entry: RemoteEntry, host: SSHHost) -> some View {
		if entry.isDirectory {
			Button {
				controller.activate(entry, host: host)
			} label: {
				MobileRemoteEntryRow(entry: entry)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Open folder \(entry.name)")
		} else {
			MobileRemoteEntryRow(entry: entry)
		}
	}

	@ViewBuilder
	private func entryActions(_ entry: RemoteEntry) -> some View {
		Button { requestRename(entry) } label: {
			Label("Rename", systemImage: "pencil")
		}
		.accessibilityLabel("Rename \(entry.name)")
		if entry.type != .unknown {
			Button(role: .destructive) { requestDelete(entry) } label: {
				Label("Delete", systemImage: "trash")
			}
			.accessibilityLabel(deleteAccessibilityLabel(entry))
		}
	}

	private func requestRename(_ entry: RemoteEntry) {
		guard let host = selectedHost,
			let context = controller.actionContext(host: host) else { return }
		nameInput = entry.name
		prompt = .rename(context, entry)
	}

	private func requestDelete(_ entry: RemoteEntry) {
		guard let host = selectedHost,
			let context = controller.actionContext(host: host) else { return }
		prompt = .delete(context, entry)
	}

	private func createFolder(context: MobileFileActionContext) {
		let name = nameInput
		Task { await controller.createFolder(named: name, context: context) }
	}

	private func rename(_ entry: RemoteEntry, context: MobileFileActionContext) {
		let name = nameInput
		Task { await controller.rename(entry, to: name, context: context) }
	}

	private func delete(_ entry: RemoteEntry, context: MobileFileActionContext) {
		Task { await controller.delete(entry, context: context) }
	}

	private func deleteAccessibilityLabel(_ entry: RemoteEntry) -> String {
		"Delete \(entry.isDirectory ? "folder" : "file") \(entry.name)"
	}

	private var promptTitle: String {
		switch prompt {
		case .createFolder: "New Folder"
		case .rename: "Rename Item"
		case .delete(_, let entry):
			"Delete \(entry.isDirectory ? "Folder" : "File") “\(entry.name)”?"
		case nil: "File Action"
		}
	}

	private var promptIsPresented: Binding<Bool> {
		Binding(
			get: { prompt != nil },
			set: { if !$0 { prompt = nil } }
		)
	}

	private var mutationFailureIsPresented: Binding<Bool> {
		Binding(
			get: { controller.mutationFailure != nil },
			set: { if !$0 { controller.dismissMutationFailure() } }
		)
	}

	private func failureView(
		_ title: String,
		message: String,
		image: String,
		host: SSHHost
	) -> some View {
		VStack(spacing: 12) {
			ContentUnavailableView(title, systemImage: image, description: Text(message))
			Button("Retry") {
				Task { await controller.refresh(host: host) }
			}
			.buttonStyle(.borderedProminent)
		}
		.listRowSeparator(.hidden)
	}

	private var hostSelection: Binding<UUID?> {
		Binding(
			get: { controller.selectedHostID },
			set: { id in
				guard let host = hosts.first(where: { $0.id == id }) else { return }
				controller.select(host: host)
			}
		)
	}

	private var selectedHost: SSHHost? {
		hosts.first { $0.id == controller.selectedHostID }
	}
}

private enum MobileFilePrompt: Identifiable {
	case createFolder(MobileFileActionContext)
	case rename(MobileFileActionContext, RemoteEntry)
	case delete(MobileFileActionContext, RemoteEntry)

	var id: String {
		switch self {
		case .createFolder(let context):
			"create-folder-\(context.host.id)-\(context.parentPath)"
		case .rename(let context, let entry):
			"rename-\(context.host.id)-\(context.parentPath)-\(entry.id)"
		case .delete(let context, let entry):
			"delete-\(context.host.id)-\(context.parentPath)-\(entry.id)"
		}
	}

	var message: String {
		switch self {
		case .createFolder(let context):
			"Create a folder in \(context.parentPath)."
		case .rename(let context, let entry):
			"Rename “\(entry.name)” in \(context.parentPath)."
		case .delete(_, let entry):
			"This permanently deletes the remote \(entry.isDirectory ? "folder" : "file") “\(entry.name)”."
		}
	}
}

private struct MobileRemoteEntryRow: View {
	let entry: RemoteEntry

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: iconName)
				.foregroundStyle(entry.isDirectory ? .blue : .secondary)
			VStack(alignment: .leading, spacing: 4) {
				Text(entry.name)
					.font(.headline)
				if entry.type == .file {
					Text(sizeDescription)
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

	private var iconName: String {
		switch entry.type {
		case .file: "doc"
		case .directory: "folder"
		case .unknown: "questionmark.square.dashed"
		}
	}

	private var sizeDescription: String {
		guard let size = entry.size else { return "Size unavailable" }
		return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
		case .conflict: "Needs Destination Choice"
		case .completed: "Completed"
		case .failed: "Failed"
		case .cancelled: "Cancelled"
		}
	}
}
