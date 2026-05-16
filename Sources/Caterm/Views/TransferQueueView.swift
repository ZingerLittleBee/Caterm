import SwiftUI
import FileTransferStore

@MainActor
struct TransferQueueView: View {
	@ObservedObject var store: FileTransferStore

	var body: some View {
		let active = store.tasks.filter { $0.status == .running || $0.status == .pending }
		let failed = store.tasks.filter { $0.status == .failed }
		if active.isEmpty && failed.isEmpty {
			EmptyView()
		} else {
			VStack(alignment: .leading, spacing: 4) {
				if let first = active.first(where: { $0.status == .running }) {
					HStack {
						ProgressView().controlSize(.small)
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
}
