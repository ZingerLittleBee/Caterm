import FileTransferStore
import SSHCommandBuilder
import SwiftUI

public struct MobileFileBrowserView: View {
	let hosts: [SSHHost]
	let transfers: [TransferTask]
	@StateObject private var controller: MobileFileBrowserController

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
				Button {
					guard let host = selectedHost else { return }
					Task { await controller.refresh(host: host) }
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.accessibilityLabel("Refresh")
				.disabled(selectedHost == nil || controller.state == .connecting)
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
	}

	@ViewBuilder
	private var browserContent: some View {
		if let host = selectedHost {
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
						Button {
							controller.activate(entry, host: host)
						} label: {
							MobileRemoteEntryRow(entry: entry)
						}
						.disabled(!entry.isDirectory)
					}
				}
			}
		}
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
