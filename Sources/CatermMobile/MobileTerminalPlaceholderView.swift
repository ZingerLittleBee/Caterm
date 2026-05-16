import SSHCommandBuilder
import SwiftUI

struct MobileTerminalPlaceholderView: View {
	let host: SSHHost?
	let snippet: String?

	var body: some View {
		ContentUnavailableView {
			Label("Terminal Unavailable", systemImage: "terminal")
		} description: {
			if let host {
				Text("Mobile terminal rendering is isolated in this phase. \(host.name) can still be configured here.")
			} else if let snippet {
				Text("Mobile terminal dispatch is isolated in this phase. The snippet is ready when a mobile renderer lands: \(snippet)")
			} else {
				Text("Mobile terminal rendering is isolated in this phase.")
			}
		}
		.navigationTitle("Terminal")
	}
}

struct MobileCredentialSetupPlaceholderView: View {
	let host: SSHHost?

	var body: some View {
		ContentUnavailableView {
			Label("Credentials Required", systemImage: "key")
		} description: {
			if let host {
				Text("Add credential material for \(host.name) before connecting.")
			} else {
				Text("Add credential material before connecting.")
			}
		}
		.navigationTitle("Credentials")
	}
}
