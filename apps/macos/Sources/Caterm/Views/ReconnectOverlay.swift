import SessionStore
import SwiftUI

struct ReconnectOverlay: View {
	let attempt: Int
	let nextRetryAt: Date
	@State var now = Date()
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	var body: some View {
		ZStack {
			Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
			VStack(spacing: 12) {
				ProgressView()
				Text("连接断开 — 正在重连 (\(attempt)/\(ReconnectScheduler.maxAttempts))")
					.font(.headline).foregroundColor(.white)
				let remaining = max(0, nextRetryAt.timeIntervalSince(now))
				if remaining > 0 {
					Text(String(format: "%.0fs", remaining)).foregroundColor(.white.opacity(0.7))
				}
			}
		}
		.onReceive(timer) { now = $0 }
	}
}
