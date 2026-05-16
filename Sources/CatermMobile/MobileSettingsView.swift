import SwiftUI

public struct MobileSettingsView: View {
	public init() {}

	public var body: some View {
		Form {
			Section("Sync") {
				Label("iCloud sync uses the existing Caterm stores.", systemImage: "icloud")
				Label("Credential material remains device-local until the sync adapter is connected.", systemImage: "key")
			}

			Section("Terminal") {
				Label("Mobile terminal rendering is isolated for this phase.", systemImage: "terminal")
			}
		}
		.navigationTitle("Settings")
	}
}
