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
						Text(
							first.kind == .upload
								? "Uploading: \((first.source as NSString).lastPathComponent)"
								: "Downloading: \((first.source as NSString).lastPathComponent)"
						)
						.lineLimit(1)
						Spacer()
						Button {
							store.cancel(first.id)
						} label: {
							Image(systemName: "xmark.circle")
						}
						.buttonStyle(.borderless)
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
					HStack {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.red)
						Text((t.source as NSString).lastPathComponent)
						Spacer()
						Button("Retry") { store.retry(t.id) }
							.buttonStyle(.borderless)
					}
					.font(.caption)
				}
			}
			.padding(8)
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
