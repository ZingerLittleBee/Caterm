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
				Text("A terminal session could not be created for \(host.name) in this app configuration. The saved Host remains available.")
			} else if let snippet {
				Text("Open a Host terminal, then run or paste \(snippet) from the terminal Snippets panel.")
			} else {
				Text("Open a Host to start a terminal session. Saved Hosts and snippets remain available when the network is offline.")
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
