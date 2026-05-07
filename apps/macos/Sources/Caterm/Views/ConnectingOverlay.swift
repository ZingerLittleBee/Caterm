import SSHCommandBuilder
import SwiftUI

public enum ConnectingStage: Equatable {
	case preflight
	case authenticating

	var label: String {
		switch self {
		case .preflight:      return "Connecting…"
		case .authenticating: return "Authenticating…"
		}
	}
}

/// Termius-style centered overlay shown during the success path of an
/// initial connect (or a retry). Not used for `.reconnecting` — that is
/// `ReconnectOverlay`'s job (it has the countdown semantics).
struct ConnectingOverlay: View {
	let stage: ConnectingStage
	let host: SSHHost
	let startedAt: Date

	@State private var now = Date()
	private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	private var elapsed: TimeInterval {
		max(0, now.timeIntervalSince(startedAt))
	}

	var body: some View {
		ZStack {
			Color.black.opacity(0.78).ignoresSafeArea()
			VStack(spacing: 10) {
				ProgressView()
					.progressViewStyle(.circular)
					.controlSize(.regular)
				Text(stage.label)
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
				hostLine
				if elapsed >= 2 {
					Text(String(format: "elapsed %.0fs", elapsed))
						.font(.system(size: 11))
						.foregroundColor(.white.opacity(0.6))
				}
			}
			.padding(.vertical, 20)
			.padding(.horizontal, 28)
		}
		.onReceive(timer) { now = $0 }
		.transition(.opacity)
	}

	private var hostLine: some View {
		HStack(spacing: 0) {
			Text(host.username).foregroundColor(Color(red: 0.47, green: 0.76, blue: 1.0))   // soft blue
			Text("@").foregroundColor(.gray)
			Text(host.hostname).foregroundColor(Color(red: 0.82, green: 0.66, blue: 1.0))   // soft purple
			Text(":\(host.port)").foregroundColor(.gray)
		}
		.font(.system(size: 13, design: .monospaced))
	}
}
