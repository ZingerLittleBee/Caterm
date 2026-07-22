import FileTransferStore
import SSHCommandBuilder
import SwiftUI
import UniformTypeIdentifiers

public struct MobileFileBrowserView: View {
	let hosts: [SSHHost]
	let transfers: [TransferTask]
	let transferStore: FileTransferStore?
	let transferWorkspace: MobileTransferWorkspace?
	@StateObject private var controller: MobileFileBrowserController
	@State private var prompt: MobileFilePrompt?
	@State private var nameInput = ""
	@State private var showingUploadImporter = false
	@State private var isUploadDropTargeted = false
	@State private var uploadContext: MobileFileActionContext?
	@State private var transferFailure: MobileTransferFailure?

	public init(
		hosts: [SSHHost] = [],
		clientFactory: MobileRemoteFileClientFactory = .unavailable,
		entries: [RemoteEntry] = [],
		transfers: [TransferTask] = [],
		transferStore: FileTransferStore? = nil,
		transferWorkspace: MobileTransferWorkspace? = nil
	) {
		self.hosts = hosts
		self.transfers = transfers
		self.transferStore = transferStore
		self.transferWorkspace = transferWorkspace
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

			if let transferStore, let transferWorkspace {
				MobileTransferQueueSection(
					store: transferStore,
					hosts: hosts,
					workspace: transferWorkspace
				)
			} else if !transfers.isEmpty {
				Section("Transfers") {
					ForEach(transfers) { task in
						MobileTransferRow(
							task: task,
							hostName: hosts.first { $0.id == task.hostId }?.name,
							export: nil,
							onCancel: {},
							onRetry: {},
							onResolveConflict: { _ in },
							onDiscard: {}
						)
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
							let context = controller.actionContext(host: host),
							transferStore != nil,
							transferWorkspace != nil else { return }
						uploadContext = context
						showingUploadImporter = true
					} label: {
						Label("Upload Files", systemImage: "arrow.up.doc")
					}
					.accessibilityLabel("Upload Files to \(controller.model.path)")
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
		.fileImporter(
			isPresented: $showingUploadImporter,
			allowedContentTypes: [.item],
			allowsMultipleSelection: true,
			onCompletion: handleUploadSelection
		)
		.dropDestination(for: URL.self) { urls, _ in
			handleUploadDrop(urls)
		} isTargeted: { isTargeted in
			isUploadDropTargeted = isTargeted
		}
		.overlay {
			if isUploadDropTargeted {
				ContentUnavailableView(
					canAcceptUploadDrop ? "Drop Files to Upload" : "Upload Unavailable",
					systemImage: canAcceptUploadDrop ? "arrow.up.doc.fill" : "nosign",
					description: Text(
						canAcceptUploadDrop
							? "Files are uploaded to \(controller.model.path). Folders are not supported yet."
							: "Connect to a Host and open a writable folder before dropping files."
					)
				)
				.padding()
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
				.padding()
				.allowsHitTesting(false)
			}
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
		.alert(item: $transferFailure) { failure in
			Alert(
				title: Text(failure.title),
				message: Text(failure.message),
				dismissButton: .default(Text("OK"))
			)
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
			Button {
				requestDownload(entry)
			} label: {
				MobileRemoteEntryRow(entry: entry)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Download file \(entry.name)")
		}
	}

	@ViewBuilder
	private func entryActions(_ entry: RemoteEntry) -> some View {
		if entry.type == .file {
			Button { requestDownload(entry) } label: {
				Label("Download", systemImage: "arrow.down.doc")
			}
			.accessibilityLabel("Download file \(entry.name)")
		}
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

	private func requestDownload(_ entry: RemoteEntry) {
		guard entry.type == .file,
			let host = selectedHost,
			let context = controller.actionContext(host: host),
			let transferStore,
			let transferWorkspace else { return }
		let remotePath = context.parentPath.appendingRemotePathComponent(entry.name)
		let actions = MobileTransferActions(
			store: transferStore,
			workspace: transferWorkspace
		)
		Task {
			do {
				_ = try await actions.download(
					remotePaths: [remotePath],
					context: context
				)
			} catch {
				transferFailure = MobileTransferFailure(
					title: "Couldn’t Start Download",
					error: error
				)
			}
		}
	}

	private func handleUploadSelection(_ result: Result<[URL], Error>) {
		guard let context = uploadContext,
			let transferStore,
			let transferWorkspace else {
			uploadContext = nil
			return
		}
		uploadContext = nil
		switch result {
		case .success(let urls):
			startUploads(urls, context: context, store: transferStore, workspace: transferWorkspace)
		case .failure(let error):
			if (error as NSError).code != NSUserCancelledError {
				transferFailure = MobileTransferFailure(
					title: "Couldn’t Select Files",
					error: error
				)
			}
		}
	}

	private var canAcceptUploadDrop: Bool {
		guard let selectedHost, let transferActions else { return false }
		return transferActions.canEnqueue(for: selectedHost.id)
			&& controller.state == .loaded
			&& controller.mutation == nil
			&& transferStore != nil
			&& transferWorkspace != nil
	}

	private func handleUploadDrop(_ urls: [URL]) -> Bool {
		guard canAcceptUploadDrop,
			let host = selectedHost,
			let context = controller.actionContext(host: host),
			let transferStore,
			let transferWorkspace else {
			transferFailure = MobileTransferFailure(
				title: "Can’t Upload Here",
				message: "Connect to a Host and open a writable folder before dropping files."
			)
			return false
		}
		startUploads(
			urls,
			context: context,
			store: transferStore,
			workspace: transferWorkspace
		)
		return true
	}

	private func startUploads(
		_ urls: [URL],
		context: MobileFileActionContext,
		store: FileTransferStore,
		workspace: MobileTransferWorkspace
	) {
		let actions = MobileTransferActions(store: store, workspace: workspace)
		Task {
			do {
				_ = try await actions.upload(sourceURLs: urls, context: context)
			} catch {
				transferFailure = MobileTransferFailure(
					title: "Couldn’t Start Upload",
					error: error
				)
			}
		}
	}

	private var transferActions: MobileTransferActions? {
		guard let transferStore, let transferWorkspace else { return nil }
		return MobileTransferActions(
			store: transferStore,
			workspace: transferWorkspace
		)
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

private struct MobileTransferQueueSection: View {
	@ObservedObject var store: FileTransferStore
	let hosts: [SSHHost]
	let workspace: MobileTransferWorkspace
	@State private var exports: [TaskId: MobileTransferExport] = [:]

	var body: some View {
		lifecycleSection
		transferSection("Active Transfers", tasks: active)
		transferSection("Failed Transfers", tasks: failed)
		transferSection("Completed Transfers", tasks: completed)
		transferSection("Cancelled Transfers", tasks: cancelled)
	}

	@ViewBuilder
	private var lifecycleSection: some View {
		if let interruption = store.lifecycleInterruption {
			Section("Transfer Interruption") {
				Label(
					interruptionMessage(interruption),
					systemImage: "pause.circle"
				)
				.foregroundStyle(.secondary)
				Button("Dismiss") { store.acknowledgeLifecycleInterruption() }
			}
		}
	}

	@ViewBuilder
	private func transferSection(_ title: String, tasks: [TransferTask]) -> some View {
		if !tasks.isEmpty {
			Section(title) {
				ForEach(tasks) { task in transferRow(task) }
			}
		}
	}

	private func transferRow(_ task: TransferTask) -> some View {
		let actions = MobileTransferActions(store: store, workspace: workspace)
		return MobileTransferRow(
			task: task,
			hostName: hosts.first { $0.id == task.hostId }?.name,
			export: exports[task.id],
			onCancel: { actions.cancel(task.id) },
			onRetry: { actions.retry(task.id) },
			onResolveConflict: { actions.resolveConflict(task.id, policy: $0) },
			onDiscard: { Task { await actions.discard(task.id) } }
		)
		.task(id: MobileTransferExportLoadID(task: task)) {
			guard task.kind == .download, task.status == .completed else {
				exports[task.id] = nil
				return
			}
			do {
				exports[task.id] = try await actions.prepareExport(for: task)
			} catch {
				NSLog("[MobileTransferQueueSection] Export preparation failed: \(error)")
				exports[task.id] = nil
			}
		}
	}

	private func interruptionMessage(
		_ interruption: TransferLifecycleInterruption
	) -> String {
		let count = interruption.transferCount
		return "iOS does not keep SSH transfers running indefinitely in the background. Caterm cancelled \(count) unfinished \(count == 1 ? "transfer" : "transfers"); retry explicitly after returning."
	}

	private var active: [TransferTask] {
		store.tasks.filter { [.pending, .running, .conflict].contains($0.status) }
	}

	private var failed: [TransferTask] {
		store.tasks.filter { $0.status == .failed }
	}

	private var completed: [TransferTask] {
		store.tasks.filter { $0.status == .completed }
	}

	private var cancelled: [TransferTask] {
		store.tasks.filter { $0.status == .cancelled }
	}
}

private struct MobileTransferExportLoadID: Hashable {
	let taskID: TaskId
	let destination: String
	let isCompletedDownload: Bool

	init(task: TransferTask) {
		self.taskID = task.id
		self.destination = task.destination
		self.isCompletedDownload = task.kind == .download && task.status == .completed
	}
}

private struct MobileTransferRow: View {
	let task: TransferTask
	let hostName: String?
	let export: MobileTransferExport?
	let onCancel: () -> Void
	let onRetry: () -> Void
	let onResolveConflict: (TransferConflictPolicy) -> Void
	let onDiscard: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Label(title, systemImage: task.kind == .upload ? "arrow.up.doc" : "arrow.down.doc")
				Spacer()
				Text(stateTitle)
					.font(.caption)
					.foregroundStyle(stateColor)
			}
			Text(hostName ?? task.hostId.uuidString)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text("From: \(task.source)")
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(1)
			Text("To: \(task.destination)")
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
			if task.status == .running {
				ProgressView(
					value: Double(task.progress.bytesTransferred),
					total: Double(task.progress.totalBytes ?? max(task.progress.bytesTransferred, 1))
				)
				Text(progressDescription)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			if let failure = task.failure {
				Text(failure.localizedDescription)
					.font(.caption)
					.foregroundStyle(.red)
			}
			controls
		}
		.accessibilityElement(children: .contain)
	}

	private var title: String {
		let name = (task.destination as NSString).lastPathComponent
		return task.kind == .upload ? "Upload \(name)" : "Download \(name)"
	}

	private var stateTitle: String {
		switch task.status {
		case .pending: "Pending"
		case .running: "Running"
		case .conflict: "Needs Destination Choice"
		case .completed: "Completed"
		case .failed: "Failed"
		case .cancelled: "Cancelled"
		}
	}

	private var stateColor: Color {
		switch task.status {
		case .completed: .green
		case .failed: .red
		case .cancelled: .secondary
		case .conflict: .orange
		case .pending, .running: .accentColor
		}
	}

	private var progressDescription: String {
		let transferred = ByteCountFormatter.string(
			fromByteCount: task.progress.bytesTransferred,
			countStyle: .file
		)
		guard let total = task.progress.totalBytes else { return transferred }
		return "\(transferred) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
	}

	@ViewBuilder
	private var controls: some View {
		switch task.status {
		case .pending, .running:
			Button("Cancel", role: .destructive, action: onCancel)
				.buttonStyle(.bordered)
		case .conflict:
			ViewThatFits(in: .horizontal) {
				conflictControls(axis: .horizontal)
				conflictControls(axis: .vertical)
			}
		case .failed, .cancelled:
			HStack {
				Button("Retry", action: onRetry)
					.buttonStyle(.borderedProminent)
				Button("Remove", role: .destructive, action: onDiscard)
					.buttonStyle(.bordered)
			}
		case .completed where task.kind == .download:
			VStack(alignment: .leading, spacing: 6) {
				if let export {
					ShareLink(item: export.fileURL) {
						Label("Share or Save to Files", systemImage: "square.and.arrow.up")
					}
					.buttonStyle(.bordered)
					Label(export.suggestedName, systemImage: "doc")
						.font(.caption)
						.padding(.vertical, 6)
						.contentShape(Rectangle())
						.draggable(export.fileURL) {
							Label(export.suggestedName, systemImage: "doc")
						}
						.accessibilityLabel("Drag downloaded file \(export.suggestedName)")
				} else {
					Label("Downloaded file is unavailable", systemImage: "exclamationmark.triangle")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Button("Remove from Queue", action: onDiscard)
					.buttonStyle(.bordered)
				Text("On iPad, drag this completed file into Files or another accepting app.")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		case .completed:
			Button("Remove from Queue", action: onDiscard)
				.buttonStyle(.bordered)
		}
	}

	private func conflictControls(axis: Axis) -> some View {
		Group {
			if axis == .horizontal {
				HStack {
					conflictButtons
				}
			} else {
				VStack(alignment: .leading) {
					conflictButtons
				}
			}
		}
		.buttonStyle(.bordered)
	}

	@ViewBuilder
	private var conflictButtons: some View {
		Button("Replace") { onResolveConflict(.replace) }
		Button("Keep Both") { onResolveConflict(.keepBoth) }
		Button("Cancel", role: .cancel) { onResolveConflict(.cancel) }
	}
}

private struct MobileTransferFailure: Identifiable {
	let id = UUID()
	let title: String
	let message: String

	init(title: String, error: Error) {
		self.title = title
		self.message = error.localizedDescription
	}

	init(title: String, message: String) {
		self.title = title
		self.message = message
	}
}
