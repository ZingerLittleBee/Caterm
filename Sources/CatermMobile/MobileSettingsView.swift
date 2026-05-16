import SwiftUI

public struct MobileSettingsView: View {
	public init() {}

	public var body: some View {
		Form {
			Section("Storage") {
				Label("Hosts persist to this device using the same on-disk format as the Mac app.", systemImage: "externaldrive")
				Label("Host secrets are saved to the device keychain.", systemImage: "key")
			}

			Section("Sync") {
				Label("iCloud/CloudKit sync across devices is not wired yet in this phase.", systemImage: "icloud")
			}

			Section("Terminal & Files") {
				Label("Mobile terminal rendering is isolated for this phase.", systemImage: "terminal")
				Label("Remote file browsing needs the platform-safe SSH transport that ships with the mobile terminal.", systemImage: "folder")
			}
		}
		.navigationTitle("Settings")
	}
}
