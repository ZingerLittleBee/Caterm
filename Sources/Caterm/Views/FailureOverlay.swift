import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Overlay shown when a connection attempt fails (preflight failure or
/// `.authOrSetupFail`). Stays visible until the user clicks Retry / Edit
/// Host or closes the tab.
struct FailureOverlay: View {
	let failure: FailureKind
	let host: SSHHost
	let chain: [SSHHost]
	let onRetry: () -> Void
	let onEditHost: (() -> Void)?
	var onClosePane: (() -> Void)? = nil

	private var presentation: FailurePresentation {
		FailurePresentation.from(failure: failure, host: host)
	}

	var body: some View {
		ZStack {
			Color.black.opacity(0.78).ignoresSafeArea()
			VStack(spacing: 10) {
				icon
				Text(presentation.title)
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
				if let detail = presentation.detail, !detail.isEmpty {
					Text(detail)
						.font(.system(size: 12, design: .monospaced))
						.foregroundColor(.white.opacity(0.7))
						.multilineTextAlignment(.center)
						.lineLimit(2)
						.frame(maxWidth: 360)
				}
				actions.padding(.top, 4)
			}
			.padding(.vertical, 20)
			.padding(.horizontal, 28)
		}
	}

	private var icon: some View {
		let bg: Color = (presentation.icon == .red) ? .red : .orange
		return ZStack {
			Circle().fill(bg)
			Text("!").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
		}
		.frame(width: 22, height: 22)
	}

	private var hostLine: some View {
		HStack(spacing: 0) {
			Text(host.username).foregroundColor(Color(red: 0.47, green: 0.76, blue: 1.0))
			Text("@").foregroundColor(.gray)
			Text(host.hostname).foregroundColor(Color(red: 0.82, green: 0.66, blue: 1.0))
		}
		.font(.system(size: 13, design: .monospaced))
	}

	private var actions: some View {
		HStack(spacing: 8) {
			Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
			if let onEditHost {
				Button("Edit Host", action: onEditHost).buttonStyle(.bordered)
			}
			if let onClosePane {
				Button("Close Pane", action: onClosePane).buttonStyle(.bordered)
			}
		}
	}
}
