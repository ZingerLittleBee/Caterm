import SessionStore
import SSHCommandBuilder
import SwiftUI

struct ReconnectOverlay: View {
	let attempt: Int
	let nextRetryAt: Date
	let host: SSHHost
	let chain: [SSHHost]
	@State var now = Date()
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	var body: some View {
		ZStack {
			Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
			VStack(spacing: 12) {
				ProgressView()
				Text("连接断开 — 正在重连 (\(attempt)/\(ReconnectScheduler.maxAttempts))")
					.font(.headline).foregroundColor(.white)
				hostLine
				if !chain.isEmpty {
					Text("via \(chain.map { "\($0.username)@\($0.hostname)" }.joined(separator: " → "))")
						.font(.caption)
						.foregroundColor(.white.opacity(0.6))
						.lineLimit(2)
						.truncationMode(.middle)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 360)
				}
				let remaining = max(0, nextRetryAt.timeIntervalSince(now))
				if remaining > 0 {
					Text(String(format: "%.0fs", remaining)).foregroundColor(.white.opacity(0.7))
				}
			}
		}
		.onReceive(timer) { now = $0 }
	}

	private var hostLine: some View {
		HStack(spacing: 0) {
			Text(host.username).foregroundColor(Color(red: 0.47, green: 0.76, blue: 1.0))
			Text("@").foregroundColor(.gray)
			Text(host.hostname).foregroundColor(Color(red: 0.82, green: 0.66, blue: 1.0))
			Text(":\(host.port)").foregroundColor(.gray)
		}
		.font(.system(size: 13, design: .monospaced))
	}
}
