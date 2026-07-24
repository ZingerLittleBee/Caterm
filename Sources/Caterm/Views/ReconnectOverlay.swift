import SessionStore
import SSHCommandBuilder
import SwiftUI

struct ReconnectOverlay: View {
	let attempt: Int
	let nextRetryAt: Date
	let host: SSHHost
	let chain: [SSHHost]
	let onRetry: () -> Void
	let onStop: () -> Void
	let onClosePane: () -> Void
	@State var now = Date()
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack {
			Spacer()
			VStack(spacing: 8) {
				ProgressView()
				Text("Reconnecting (\(attempt)/\(ReconnectScheduler.maxAttempts))")
					.font(.headline)
				hostLine
				if !chain.isEmpty {
					Text("via \(chain.map { "\($0.username)@\($0.hostname)" }.joined(separator: " → "))")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(2)
						.truncationMode(.middle)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 360)
				}
				let remaining = max(0, nextRetryAt.timeIntervalSince(now))
				if remaining > 0 {
					Text(String(format: "Retrying in %.0fs", remaining))
						.foregroundStyle(.secondary)
				}
				HStack(spacing: 8) {
					Button("Retry Now", action: onRetry)
						.buttonStyle(.borderedProminent)
					Button("Stop", action: onStop)
					Button("Close Pane", action: onClosePane)
				}
			}
			.padding(12)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
			.padding(12)
		}
		.onReceive(timer) { now = $0 }
	}

	private var hostLine: some View {
		HStack(spacing: 0) {
			Text(host.username).foregroundStyle(.secondary)
			Text("@").foregroundStyle(.tertiary)
			Text(host.hostname)
			Text(":\(host.port)").foregroundStyle(.secondary)
		}
		.font(.system(size: 13, design: .monospaced))
	}
}
