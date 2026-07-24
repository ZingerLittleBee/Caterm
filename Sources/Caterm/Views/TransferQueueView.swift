import SwiftUI
import FileTransferStore

@MainActor
struct TransferQueueView: View {
	@ObservedObject var store: FileTransferStore

	var body: some View {
		let active = store.tasks.filter { $0.status == .running || $0.status == .pending }
		let conflicts = store.tasks.filter { $0.status == .conflict }
		let failed = store.tasks.filter { $0.status == .failed }
		if active.isEmpty && conflicts.isEmpty && failed.isEmpty {
			EmptyView()
		} else {
			VStack(alignment: .leading, spacing: 4) {
				if let first = active.first(where: { $0.status == .running }) {
					HStack {
						transferProgress(first)
						Text(activeDescription(first))
						.lineLimit(1)
						Spacer()
						Button {
							store.cancel(first.id)
						} label: {
							Image(systemName: "xmark.circle")
						}
						.buttonStyle(.borderless)
						.accessibilityLabel("Cancel Transfer")
					}
				}
				if active.count > 1 {
					Text("\(active.count - 1) queued")
						.foregroundStyle(.secondary)
						.font(.caption)
				}
				ForEach(conflicts) { task in
					VStack(alignment: .leading, spacing: 4) {
						Label("Destination already exists", systemImage: "doc.on.doc")
							.font(.caption)
						Text(task.destination)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
						HStack {
							Button("Replace") {
								store.resolveConflict(task.id, policy: .replace)
							}
							Button("Keep Both") {
								store.resolveConflict(task.id, policy: .keepBoth)
							}
							Button("Cancel") {
								store.resolveConflict(task.id, policy: .cancel)
							}
						}
						.buttonStyle(.borderless)
						.font(.caption)
					}
				}
				ForEach(failed) { t in
					VStack(alignment: .leading, spacing: 2) {
						HStack {
							Image(systemName: "exclamationmark.triangle.fill")
								.foregroundStyle(.red)
							Text((t.source as NSString).lastPathComponent)
							Spacer()
							Button("Retry") { store.retry(t.id) }
								.buttonStyle(.borderless)
						}
						if let failure = t.failure {
							Text(failure.localizedDescription)
								.foregroundStyle(.secondary)
								.lineLimit(2)
								.accessibilityLabel(
									"Transfer failed: \(failure.localizedDescription)"
								)
						}
					}
					.font(.caption)
				}
			}
			.padding(8)
		}
	}

	private func activeDescription(_ task: TransferTask) -> String {
		let name = (task.source as NSString).lastPathComponent
		switch task.kind {
		case .upload:
			return "Uploading: \(name)"
		case .download:
			return "Downloading: \(name)"
		case .remoteCopy:
			return "Copying through this Mac: \(name)"
		}
	}

	@ViewBuilder
	private func transferProgress(_ task: TransferTask) -> some View {
		if let total = task.progress.totalBytes, total > 0 {
			ProgressView(
				value: Double(task.progress.bytesTransferred),
				total: Double(total)
			)
			.frame(width: 48)
		} else {
			ProgressView()
				.controlSize(.small)
		}
	}
}
