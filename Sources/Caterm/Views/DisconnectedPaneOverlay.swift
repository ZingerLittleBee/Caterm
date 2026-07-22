import SessionStore
import SSHCommandBuilder
import SwiftUI

struct DisconnectedPaneOverlay: View {
	let failure: FailureKind
	let host: SSHHost
	let onRetry: () -> Void
	let onEditHost: (() -> Void)?
	let onClosePane: () -> Void

	private var title: String {
		failure == .cleanExit ? "Session Ended" : "Connection Lost"
	}

	var body: some View {
		VStack {
			Spacer()
			HStack(spacing: 10) {
				Image(systemName: failure == .cleanExit ? "checkmark.circle" : "wifi.exclamationmark")
				Text(title).fontWeight(.semibold)
				Text("\(host.username)@\(host.hostname)")
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
				Spacer(minLength: 8)
				Button("Retry", action: onRetry)
					.buttonStyle(.borderedProminent)
				if let onEditHost {
					Button("Edit Host", action: onEditHost)
				}
				Button("Close Pane", action: onClosePane)
			}
			.padding(10)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
			.padding(10)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title)
	}
}
