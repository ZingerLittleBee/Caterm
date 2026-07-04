import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI
#if canImport(UIKit)
import CatermMobileTerminal
#endif

public struct MobileSettingsView: View {
	private var hosts: Binding<[SSHHost]>?
	private var snippets: Binding<[Snippet]>?

	/// Pass the shell's host/snippet bindings to enable the Backup
	/// (encrypted export/import) section; nil hides it (previews/tests).
	public init(hosts: Binding<[SSHHost]>? = nil,
	            snippets: Binding<[Snippet]>? = nil) {
		self.hosts = hosts
		self.snippets = snippets
	}

	public var body: some View {
		#if canImport(UIKit)
		MobileSettingsForm(hosts: hosts, snippets: snippets)
		#else
		Form {
			Section("About") {
				Label("Caterm mobile settings are available on iOS.", systemImage: "gearshape")
			}
		}
		.navigationTitle("Settings")
		#endif
	}
}

#if canImport(UIKit)
private struct MobileSettingsForm: View {
	var hosts: Binding<[SSHHost]>?
	var snippets: Binding<[Snippet]>?

	@AppStorage(MobileTerminalSettings.Keys.defaultThemeID)
	private var themeID: String = TerminalTheme.presets[0].id
	@AppStorage(MobileTerminalSettings.Keys.fontSize)
	private var fontSize: Double = MobileTerminalSettings.defaultFontSize
	@AppStorage(MobileTerminalSettings.Keys.defaultKeyboardNative)
	private var keyboardNative: Bool = false

	var body: some View {
		Form {
			Section {
				Picker("Theme", selection: $themeID) {
					ForEach(TerminalTheme.presets) { theme in
						Text(theme.name).tag(theme.id)
					}
				}

				Stepper(value: $fontSize,
					in: MobileTerminalSettings.fontSizeRange, step: 1) {
					LabeledContent("Font Size", value: "\(Int(fontSize)) pt")
				}
			} header: {
				Text("Terminal Appearance")
			} footer: {
				Text("Applies to connections opened from now on.")
			}

			Section {
				Picker("Default Keyboard", selection: $keyboardNative) {
					Text("Custom keys").tag(false)
					Text("Native iOS").tag(true)
				}
			} header: {
				Text("Keyboard")
			} footer: {
				Text("You can still toggle the keyboard inside any session.")
			}

			if let hosts, let snippets {
				MobileBackupSection(hosts: hosts, snippets: snippets)
			}

			Section("Data") {
				Label("Hosts persist to this device using the same on-disk format as the Mac app.",
					systemImage: "externaldrive")
				Label("Host secrets are saved to the device keychain.",
					systemImage: "key")
				Label("iCloud/CloudKit sync across devices is not wired yet in this phase.",
					systemImage: "icloud")
			}

			Section("About") {
				LabeledContent("Version", value: appVersion)
			}
		}
		.navigationTitle("Settings")
	}

	private var appVersion: String {
		let info = Bundle.main.infoDictionary
		let short = info?["CFBundleShortVersionString"] as? String ?? "—"
		let build = info?["CFBundleVersion"] as? String ?? "—"
		return "\(short) (\(build))"
	}
}
#endif
