import AppKit
import CoreTransferable
import FileTransferStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import UniformTypeIdentifiers

enum SFTPTaskWindow {
	static let id = "sftp-task"
}

private extension UTType {
	static let catermSFTPTaskEntry = UTType(
		exportedAs: "com.zingerlittlebee.caterm.sftp-task-entry"
	)
}

private struct SFTPTaskDragPayload: Codable, Transferable {
	let sourceSide: SFTPTaskSide
	let entryID: SFTPTaskEntry.ID

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .catermSFTPTaskEntry)
	}
}

@MainActor
struct SFTPTaskWindowView: View {
	@EnvironmentObject private var sessionStore: SessionStore
	@EnvironmentObject private var transferStore: FileTransferStore
	@StateObject private var model = SFTPTaskWindowModel()
	@StateObject private var externalEditor =
		RemoteExternalEditorCoordinator()

	var body: some View {
		VStack(spacing: 0) {
			HSplitView {
				SFTPTaskPaneView(
					side: .left,
					model: model,
					externalEditor: externalEditor
				)
					.environmentObject(sessionStore)
					.environmentObject(transferStore)
					.frame(minWidth: 420)
				SFTPTaskPaneView(
					side: .right,
					model: model,
					externalEditor: externalEditor
				)
					.environmentObject(sessionStore)
					.environmentObject(transferStore)
					.frame(minWidth: 420)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)

			if let notice = model.transferNotice {
				Divider()
				HStack(spacing: 8) {
					Image(systemName: "info.circle")
						.foregroundStyle(.secondary)
					Text(notice)
						.font(.callout)
					Spacer()
					Button {
						model.dismissTransferNotice()
					} label: {
						Image(systemName: "xmark")
					}
					.buttonStyle(.borderless)
					.accessibilityLabel("Dismiss Transfer Notice")
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.background(.bar)
			}

			Divider()
			TransferQueueView(store: transferStore)
				.background(.thickMaterial)
		}
		.task {
			await model.bootstrap(
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
		.onChange(of: sessionStore.hosts) {
			Task {
				await model.refresh(
					.left,
					hosts: sessionStore.hosts,
					transferStore: transferStore
				)
				await model.refresh(
					.right,
					hosts: sessionStore.hosts,
					transferStore: transferStore
				)
			}
		}
		.onDisappear {
			Task {
				await externalEditor.closeAll()
			}
		}
		.navigationTitle("File Transfer")
		.accessibilityIdentifier("sftp-task-window")
		.background(
			SFTPTaskWindowCloseGuard(
				shouldConfirm: !externalEditor.sessions.isEmpty,
				onDiscardAndClose: {
					await externalEditor.closeAll()
				}
			)
		)
	}
}

@MainActor
private struct SFTPTaskPaneView: View {
	let side: SFTPTaskSide
	@ObservedObject var model: SFTPTaskWindowModel
	@ObservedObject var externalEditor: RemoteExternalEditorCoordinator
	@EnvironmentObject private var sessionStore: SessionStore
	@EnvironmentObject private var transferStore: FileTransferStore
	@State private var pathDraft = ""
	@State private var isDropTargeted = false

	private var pane: SFTPTaskPaneState {
		model.state(for: side)
	}

	private var entries: [SFTPTaskEntry] {
		model.entries(for: side)
	}

	private var selection: Binding<Set<SFTPTaskEntry.ID>> {
		Binding(
			get: { pane.selection },
			set: { model.setSelection($0, for: side) }
		)
	}

	var body: some View {
		VStack(spacing: 0) {
			endpointBar
			Divider()
			navigationBar
			Divider()
			content
			if let session = externalEditor.session(for: side) {
				Divider()
				RemoteExternalEditBanner(
					session: session,
					onReviewUpload: {
						Task {
							await externalEditor.reviewUpload(side: side)
						}
					},
					onUpload: {
						Task {
							await externalEditor.upload(
								side: side,
								replacingRemote: false
							)
						}
					},
					onReplaceRemote: {
						Task {
							await externalEditor.upload(
								side: side,
								replacingRemote: true
							)
						}
					},
					onDownloadNewer: {
						Task {
							await externalEditor.downloadNewer(side: side)
						}
					},
					onKeepEditing: {
						externalEditor.keepEditing(side: side)
					},
					onRetry: {
						Task {
							await externalEditor.retry(side: side)
						}
					},
					onClose: {
						Task {
							await externalEditor.close(side: side)
						}
					}
				)
			}
		}
		.background {
			if isDropTargeted {
				RoundedRectangle(cornerRadius: 8)
					.stroke(.tint, lineWidth: 2)
					.padding(3)
			}
		}
		.dropDestination(for: SFTPTaskDragPayload.self) {
			payloads,
			_ in
			guard let payload = payloads.first,
				payload.sourceSide != side else {
				return false
			}
			Task {
				_ = await model.copy(
					entryIDs: Set(payloads.map(\.entryID)),
					from: payload.sourceSide,
					hosts: sessionStore.hosts,
					transferStore: transferStore
				)
			}
			return true
		} isTargeted: {
			isDropTargeted = $0
		}
		.task(
			id: SFTPTaskPathIdentity(
				endpoint: pane.endpoint,
				path: pane.path
			)
		) {
			pathDraft = pane.path
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(side == .left ? "Left File Pane" : "Right File Pane")
		.accessibilityIdentifier("sftp-task-\(side.rawValue)-pane")
	}

	private var endpointBar: some View {
		HStack(spacing: 8) {
			Menu {
				Button("Choose Local Folder…") {
					chooseLocalFolder(replacing: nil)
				}
				if !model.locations.isEmpty {
					Section("Local Locations") {
						ForEach(model.locations) { location in
							Button(location.displayName) {
								selectLocal(location.id)
							}
						}
					}
				}
				if !sessionStore.hosts.isEmpty {
					Section("Hosts") {
						ForEach(sessionStore.hosts) { host in
							Button(host.name) {
								selectRemote(host.id)
							}
						}
					}
				}
			} label: {
				Label(endpointTitle, systemImage: endpointIcon)
					.lineLimit(1)
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.disabled(externalEditor.session(for: side) != nil)
			.accessibilityLabel(
				side == .left
					? "Left Pane Location"
					: "Right Pane Location"
			)

			Spacer(minLength: 8)

			Button {
				copySelection()
			} label: {
				Label(copyTitle, systemImage: copyIcon)
			}
			.disabled(pane.selection.isEmpty || copyRouteUnavailable)
			.help(copyTitle)
			.accessibilityHint("Copies the selected items without changing the active terminal")
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}

	private var navigationBar: some View {
		HStack(spacing: 6) {
			Button {
				Task {
					await model.goBack(
						side,
						hosts: sessionStore.hosts,
						transferStore: transferStore
					)
				}
			} label: {
				Image(systemName: "chevron.left")
			}
			.disabled(!pane.canGoBack)
			.accessibilityLabel("Back")

			Button {
				Task {
					await model.goForward(
						side,
						hosts: sessionStore.hosts,
						transferStore: transferStore
					)
				}
			} label: {
				Image(systemName: "chevron.right")
			}
			.disabled(!pane.canGoForward)
			.accessibilityLabel("Forward")

			Button {
				Task {
					await model.goUp(
						side,
						hosts: sessionStore.hosts,
						transferStore: transferStore
					)
				}
			} label: {
				Image(systemName: "arrow.up")
			}
			.disabled(!canGoUp)
			.accessibilityLabel("Parent Folder")

			TextField("Path", text: $pathDraft)
				.textFieldStyle(.roundedBorder)
				.font(.system(.body, design: .monospaced))
				.onSubmit {
					Task {
						await model.navigate(
							side,
							to: pathDraft,
							hosts: sessionStore.hosts,
							transferStore: transferStore
						)
					}
				}
				.disabled(pane.endpoint == .unconfigured)
				.accessibilityLabel("Current Path")

			Button {
				model.setShowsHiddenFiles(
					!pane.showsHiddenFiles,
					for: side
				)
			} label: {
				Image(
					systemName: pane.showsHiddenFiles
						? "eye"
						: "eye.slash"
				)
			}
			.accessibilityLabel(
				pane.showsHiddenFiles
					? "Hide Hidden Files"
					: "Show Hidden Files"
			)
			.help(
				pane.showsHiddenFiles
					? "Hide Hidden Files"
					: "Show Hidden Files"
			)

			Button {
				refresh()
			} label: {
				Image(systemName: "arrow.clockwise")
			}
			.disabled(pane.endpoint == .unconfigured)
			.accessibilityLabel("Refresh")
		}
		.buttonStyle(.borderless)
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
	}

	@ViewBuilder
	private var content: some View {
		switch pane.endpoint {
		case .unconfigured:
			ContentUnavailableView {
				Label("Choose a Location", systemImage: "folder")
			} description: {
				Text("Choose a saved Host or authorize a local folder.")
			} actions: {
				Button("Choose Local Folder…") {
					chooseLocalFolder(replacing: nil)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		default:
			if let error = model.error(for: side) {
				ContentUnavailableView {
					Label(
						"Unable to Open Location",
						systemImage: "exclamationmark.triangle"
					)
				} description: {
					Text(error)
				} actions: {
					if case .local(let locationID) = pane.endpoint {
						Button("Choose Folder Again…") {
							chooseLocalFolder(replacing: locationID)
						}
					}
					Button("Try Again") {
						refresh()
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if model.isLoading(side), entries.isEmpty {
				ProgressView("Loading…")
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				entryTable
					.overlay {
						if entries.isEmpty, !model.isLoading(side) {
							ContentUnavailableView(
								"Empty Folder",
								systemImage: "folder"
							)
						}
					}
			}
		}
	}

	private var entryTable: some View {
		Table(entries, selection: selection) {
			TableColumn("Name") { entry in
				HStack(spacing: 6) {
					Image(
						systemName: entry.isDirectory
							? "folder.fill"
							: "doc"
					)
					.foregroundStyle(
						entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
					)
					Text(entry.name)
						.lineLimit(1)
				}
				.contentShape(Rectangle())
				.onTapGesture(count: 2) {
					Task {
						await model.open(
							entry,
							in: side,
							hosts: sessionStore.hosts,
							transferStore: transferStore
						)
					}
				}
				.draggable(
					SFTPTaskDragPayload(
						sourceSide: side,
						entryID: entry.id
					)
				)
			}
			.width(min: 180, ideal: 260)

			TableColumn("Modified") { entry in
				Text(
					entry.modifiedAt?.formatted(
						date: .abbreviated,
						time: .shortened
					) ?? "—"
				)
				.foregroundStyle(.secondary)
			}
			.width(min: 120, ideal: 150)

			TableColumn("Size") { entry in
				Text(sizeDescription(for: entry))
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .trailing)
			}
			.width(min: 72, ideal: 88)

			TableColumn("Kind") { entry in
				Text(kindDescription(for: entry))
					.foregroundStyle(.secondary)
			}
			.width(min: 68, ideal: 86)
		}
		.contextMenu(forSelectionType: SFTPTaskEntry.ID.self) {
			selectedIDs in
			Button(copyTitle) {
				Task {
					_ = await model.copy(
						entryIDs: selectedIDs,
						from: side,
						hosts: sessionStore.hosts,
						transferStore: transferStore
					)
				}
			}
			.disabled(selectedIDs.isEmpty || copyRouteUnavailable)
			if let entry = externalEditEntry(in: selectedIDs) {
				Button("Edit Externally…") {
					chooseEditorAndStart(for: entry)
				}
				.disabled(externalEditor.session(for: side) != nil)
			}
		}
		.onKeyPress(.return) {
			guard pane.selection.count == 1,
				let entry = entries.first(where: {
					pane.selection.contains($0.id)
				}) else {
				return .ignored
			}
			Task {
				await model.open(
					entry,
					in: side,
					hosts: sessionStore.hosts,
					transferStore: transferStore
				)
			}
			return .handled
		}
	}

	private var endpointTitle: String {
		switch pane.endpoint {
		case .unconfigured:
			"Choose Location"
		case .local(let locationID):
			model.locations.first { $0.id == locationID }?.displayName
				?? "Local Folder"
		case .remote(let hostID):
			sessionStore.hosts.first { $0.id == hostID }?.name
				?? "Unavailable Host"
		}
	}

	private var endpointIcon: String {
		switch pane.endpoint {
		case .unconfigured:
			"questionmark.folder"
		case .local:
			"macbook"
		case .remote:
			"server.rack"
		}
	}

	private var copyTitle: String {
		side == .left ? "Copy to Right" : "Copy to Left"
	}

	private var copyIcon: String {
		side == .left ? "arrow.right" : "arrow.left"
	}

	private var copyRouteUnavailable: Bool {
		SFTPTaskTransferRoute.resolve(
			source: pane.endpoint,
			destination: model.state(for: side.opposite).endpoint
		) == nil
	}

	private var canGoUp: Bool {
		switch pane.endpoint {
		case .unconfigured:
			false
		case .local:
			!pane.path.isEmpty
		case .remote:
			pane.path != "~" && pane.path != "/"
		}
	}

	private func chooseLocalFolder(replacing locationID: UUID?) {
		Task {
			guard let url = await chooseURL(
				message: "Choose a local folder for this file pane.",
				prompt: "Choose",
				contentTypes: [.folder],
				canChooseDirectories: true,
				directoryURL: nil
			) else {
				return
			}
			defer { url.stopAccessingSecurityScopedResource() }
			await model.authorizeLocal(
				url: url,
				replacing: locationID,
				for: side,
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
	}

	private func chooseURL(
		message: String,
		prompt: String,
		contentTypes: [UTType],
		canChooseDirectories: Bool,
		directoryURL: URL?
	) async -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = !canChooseDirectories
		panel.canChooseDirectories = canChooseDirectories
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = canChooseDirectories
		panel.allowedContentTypes = contentTypes
		panel.prompt = prompt
		panel.message = message
		panel.directoryURL = directoryURL
		return await withCheckedContinuation { continuation in
			panel.begin { response in
				continuation.resume(
					returning: response == .OK ? panel.url : nil
				)
			}
		}
	}

	private func selectLocal(_ locationID: UUID) {
		Task {
			await model.selectLocal(
				locationID: locationID,
				for: side,
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
	}

	private func selectRemote(_ hostID: UUID) {
		Task {
			await model.selectRemote(
				hostID: hostID,
				for: side,
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
	}

	private func copySelection() {
		Task {
			_ = await model.copy(
				from: side,
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
	}

	private func externalEditEntry(
		in selectedIDs: Set<SFTPTaskEntry.ID>
	) -> SFTPTaskEntry? {
		guard case .remote = pane.endpoint,
			selectedIDs.count == 1,
			let entry = entries.first(where: {
				selectedIDs.contains($0.id)
			}),
			entry.kind == .file else {
			return nil
		}
		return entry
	}

	private func chooseEditorAndStart(for entry: SFTPTaskEntry) {
		guard case .remote(let hostID) = pane.endpoint,
			let host = sessionStore.hosts.first(where: {
				$0.id == hostID
			}) else {
			return
		}
		let remotePath = (pane.path as NSString)
			.appendingPathComponent(entry.name)
		Task {
			guard let editorURL = await chooseURL(
				message: "Choose the app that should edit \(entry.name).",
				prompt: "Choose Editor",
				contentTypes: [.applicationBundle],
				canChooseDirectories: false,
				directoryURL: URL(
					fileURLWithPath: "/Applications",
					isDirectory: true
				)
			) else {
				return
			}
			defer { editorURL.stopAccessingSecurityScopedResource() }
			await externalEditor.start(
				side: side,
				remotePath: remotePath,
				editorURL: editorURL,
				host: host,
				transferStore: transferStore
			)
		}
	}

	private func refresh() {
		Task {
			await model.refresh(
				side,
				hosts: sessionStore.hosts,
				transferStore: transferStore
			)
		}
	}

	private func sizeDescription(for entry: SFTPTaskEntry) -> String {
		guard !entry.isDirectory, let size = entry.size else {
			return "—"
		}
		return ByteCountFormatter.string(
			fromByteCount: size,
			countStyle: .file
		)
	}

	private func kindDescription(for entry: SFTPTaskEntry) -> String {
		switch entry.kind {
		case .file:
			"File"
		case .directory:
			"Folder"
		case .unknown:
			"Other"
		}
	}
}

private struct SFTPTaskPathIdentity: Hashable {
	let endpoint: SFTPTaskEndpoint
	let path: String
}

private struct RemoteExternalEditBanner: View {
	let session: RemoteExternalEditSession
	let onReviewUpload: () -> Void
	let onUpload: () -> Void
	let onReplaceRemote: () -> Void
	let onDownloadNewer: () -> Void
	let onKeepEditing: () -> Void
	let onRetry: () -> Void
	let onClose: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			statusIcon
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.callout.weight(.medium))
					.lineLimit(1)
				Text(detail)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			Spacer(minLength: 8)
			actions
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.background(.bar)
		.accessibilityElement(children: .contain)
		.accessibilityLabel("External Editor Status")
	}

	@ViewBuilder
	private var statusIcon: some View {
		switch session.state {
		case .preparing, .reviewing, .uploading, .downloadingNewer:
			ProgressView()
				.controlSize(.small)
		case .failed:
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.red)
		case .conflict:
			Image(systemName: "arrow.triangle.branch")
				.foregroundStyle(.orange)
		case .modified, .awaitingUploadConfirmation:
			Image(systemName: "pencil.circle.fill")
				.foregroundStyle(.tint)
		case .watching(let uploadedAt):
			Image(
				systemName: uploadedAt == nil
					? "eye"
					: "checkmark.circle.fill"
			)
			.foregroundStyle(
				uploadedAt == nil
					? AnyShapeStyle(.secondary)
					: AnyShapeStyle(.green)
			)
		}
	}

	@ViewBuilder
	private var actions: some View {
		switch session.state {
		case .preparing, .reviewing, .uploading, .downloadingNewer:
			Button("Cancel", action: onClose)
		case .watching:
			Button("Stop Editing", action: onClose)
		case .modified:
			Button("Review Upload", action: onReviewUpload)
				.buttonStyle(.borderedProminent)
			Button("Discard Draft", role: .destructive, action: onClose)
		case .awaitingUploadConfirmation:
			Button("Upload Changes", action: onUpload)
				.buttonStyle(.borderedProminent)
			Button("Keep Editing", action: onKeepEditing)
			Button("Discard Draft", role: .destructive, action: onClose)
		case .conflict:
			Button("Download Newer", action: onDownloadNewer)
			Button("Replace Remote", role: .destructive, action: onReplaceRemote)
			Button("Cancel", action: onKeepEditing)
		case .failed(_, let retry):
			if retry != nil {
				Button("Retry", action: onRetry)
					.buttonStyle(.borderedProminent)
			}
			Button("Stop Editing", action: onClose)
		}
	}

	private var title: String {
		switch session.state {
		case .preparing:
			"Preparing \(session.fileName)…"
		case .watching(let uploadedAt):
			uploadedAt == nil
				? "Editing \(session.fileName)"
				: "Uploaded \(session.fileName)"
		case .modified:
			"Local changes detected"
		case .reviewing:
			"Checking the remote file…"
		case .awaitingUploadConfirmation:
			"Upload local changes?"
		case .conflict:
			"Remote file may have changed"
		case .uploading:
			"Uploading changes…"
		case .downloadingNewer:
			"Downloading the remote version…"
		case .failed:
			"External edit failed"
		}
	}

	private var detail: String {
		switch session.state {
		case .preparing:
			return "Downloading to a private staging folder."
		case .watching:
			return "Watching the private draft opened in \(session.editorName)."
		case .modified:
			return "Review before Caterm uploads anything to the Host."
		case .reviewing:
			return session.remotePath
		case .awaitingUploadConfirmation:
			return "The remote revision still matches the staged download."
		case .conflict(let metadata):
			let reason = conflictReason(metadata)
			return "\(reason) Downloaded: \(revisionDescription(metadata.baseline)). Current: \(revisionDescription(metadata.current))."
		case .uploading:
			return "Publishing through a temporary sibling, then renaming atomically."
		case .downloadingNewer:
			return "Your local draft will be replaced by the newer remote file."
		case .failed(let message, _):
			return message
		}
	}

	private func conflictReason(
		_ metadata: RemoteEditConflictMetadata
	) -> String {
		if let baselineDigest = metadata.baseline.contentDigest,
			let currentDigest = metadata.current.contentDigest,
			baselineDigest != currentDigest {
			return "Remote content changed (verified by SHA-256)."
		}
		if metadata.baseline.size != metadata.current.size {
			return "Remote file size changed."
		}
		if metadata.baseline.modifiedAt != metadata.current.modifiedAt {
			return "Remote modification time changed."
		}
		return "The server cannot prove this revision is unchanged."
	}

	private func revisionDescription(
		_ revision: RemoteFileRevision
	) -> String {
		let size = revision.size.map {
			ByteCountFormatter.string(
				fromByteCount: $0,
				countStyle: .file
			)
		} ?? "unknown size"
		let modified = revision.modifiedAt?.formatted(
			date: .abbreviated,
			time: .shortened
		) ?? "unknown modified time"
		return "\(size), \(modified)"
	}
}

private struct SFTPTaskWindowCloseGuard: NSViewRepresentable {
	let shouldConfirm: Bool
	let onDiscardAndClose: @MainActor () async -> Bool

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSView {
		let view = WindowObservationView(frame: .zero)
		view.onWindowChange = { [weak coordinator = context.coordinator] window in
			coordinator?.install(on: window)
		}
		return view
	}

	func updateNSView(_ view: NSView, context: Context) {
		context.coordinator.shouldConfirm = shouldConfirm
		context.coordinator.onDiscardAndClose = onDiscardAndClose
		context.coordinator.install(on: view.window)
	}

	static func dismantleNSView(
		_ nsView: NSView,
		coordinator: Coordinator
	) {
		coordinator.uninstall()
	}

	@MainActor
	final class WindowObservationView: NSView {
		var onWindowChange: @MainActor (NSWindow?) -> Void = { _ in }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			onWindowChange(window)
		}
	}

	@MainActor
	final class Coordinator: NSObject, NSWindowDelegate {
		var shouldConfirm = false
		var onDiscardAndClose: @MainActor () async -> Bool = { true }

		private weak var window: NSWindow?
		private var originalDelegate: (any NSWindowDelegate)?
		private var allowsNextClose = false
		private var isPresentingConfirmation = false

		func install(on window: NSWindow?) {
			guard let window else { return }
			if self.window === window, window.delegate === self {
				return
			}
			uninstall()
			self.window = window
			originalDelegate = window.delegate
			window.delegate = self
		}

		func uninstall() {
			guard let window, window.delegate === self else {
				self.window = nil
				originalDelegate = nil
				return
			}
			window.delegate = originalDelegate
			self.window = nil
			originalDelegate = nil
		}

		func windowShouldClose(_ sender: NSWindow) -> Bool {
			if allowsNextClose {
				allowsNextClose = false
				guard originalDelegate?.windowShouldClose?(sender) ?? true else {
					return false
				}
				return true
			}
			guard shouldConfirm else {
				return originalDelegate?.windowShouldClose?(sender) ?? true
			}
			guard !isPresentingConfirmation else { return false }
			isPresentingConfirmation = true

			let alert = NSAlert()
			alert.messageText = "Stop external editing and close?"
			alert.informativeText =
				"Closing this window discards local drafts that have not been uploaded."
			alert.alertStyle = .warning
			alert.addButton(withTitle: "Discard Drafts and Close")
			alert.addButton(withTitle: "Cancel")
			alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
				guard let self else { return }
				self.isPresentingConfirmation = false
				guard response == .alertFirstButtonReturn,
					let sender else {
					return
				}
				Task { @MainActor in
					guard await self.onDiscardAndClose() else {
						return
					}
					self.allowsNextClose = true
					sender.performClose(nil)
				}
			}
			return false
		}

		override func responds(to selector: Selector!) -> Bool {
			super.responds(to: selector)
				|| originalDelegate?.responds(to: selector) == true
		}

		override func forwardingTarget(for selector: Selector!) -> Any? {
			if originalDelegate?.responds(to: selector) == true {
				return originalDelegate
			}
			return super.forwardingTarget(for: selector)
		}
	}
}
