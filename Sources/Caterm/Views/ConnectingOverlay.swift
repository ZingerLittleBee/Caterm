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
	let chain: [SSHHost]

	@State private var now = Date()
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	private var elapsed: TimeInterval {
		max(0, now.timeIntervalSince(startedAt))
	}

	/// Surfaced one-at-a-time on the loading screen so the wait doubles as
	/// a hint about how Caterm handles keys / sync.
	private static let tips: [String] = [
		"Trying your saved key for this host…",
		"Tip: pick a key from ~/.ssh in the host editor to reuse keys you already have.",
		"Keys you explicitly choose sync across your devices with iCloud credential sync.",
		"Keys auto-found in ~/.ssh are never uploaded unless you opt in under Settings → Sync.",
		"If a key has a passphrase, Caterm asks for it and stores it in your Keychain.",
		"Hold ⌘ anywhere to reveal keyboard shortcuts.",
	]

	private var currentTip: String {
		guard stage == .authenticating, elapsed >= 1 else { return "" }
		let idx = Int(elapsed / 4) % Self.tips.count
		return Self.tips[idx]
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
				if !chain.isEmpty {
					Text("via \(chain.map { "\($0.username)@\($0.hostname)" }.joined(separator: " → "))")
						.font(.caption)
						.foregroundColor(.white.opacity(0.6))
						.lineLimit(2)
						.truncationMode(.middle)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 360)
				}
				if elapsed >= 2 {
					Text(String(format: "elapsed %.0fs", elapsed))
						.font(.system(size: 11))
						.foregroundColor(.white.opacity(0.6))
				}
				if !currentTip.isEmpty {
					Text(currentTip)
						.font(.system(size: 11))
						.foregroundColor(.white.opacity(0.55))
						.multilineTextAlignment(.center)
						.frame(maxWidth: 360)
						.transition(reduceMotion ? .identity : .opacity)
						.id(currentTip)
						.animation(
							WorkspaceMotionPolicy.tipAnimation(reduceMotion: reduceMotion),
							value: currentTip
						)
				}
			}
			.padding(.vertical, 20)
			.padding(.horizontal, 28)
		}
		.onReceive(timer) { now = $0 }
		.transition(reduceMotion ? .identity : .opacity)
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
