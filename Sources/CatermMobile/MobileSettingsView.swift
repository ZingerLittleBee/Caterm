import SnippetSyncClient
import SSHCommandBuilder
import SettingsStore
import SwiftUI
#if canImport(UIKit)
import CatermMobileTerminal
#endif

public struct MobileSettingsView: View {
	private var hosts: Binding<[SSHHost]>?
	private var snippets: Binding<[Snippet]>?
	private var settingsStore: SettingsStore?

	/// Pass the shell's host/snippet bindings to enable the Backup
	/// (encrypted export/import) section; nil hides it (previews/tests).
	public init(
		hosts: Binding<[SSHHost]>? = nil,
		snippets: Binding<[Snippet]>? = nil,
		settingsStore: SettingsStore? = nil
	) {
		self.hosts = hosts
		self.snippets = snippets
		self.settingsStore = settingsStore
	}

	public var body: some View {
		#if canImport(UIKit)
		if let settingsStore {
			MobileSyncedSettingsForm(
				store: settingsStore,
				hosts: hosts,
				snippets: snippets
			)
		} else {
			MobileLegacySettingsForm(hosts: hosts, snippets: snippets)
		}
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
private struct MobileLegacySettingsForm: View {
	var hosts: Binding<[SSHHost]>?
	var snippets: Binding<[Snippet]>?

	@AppStorage(MobileTerminalSettings.Keys.defaultThemeID)
	private var themeID: String = TerminalTheme.presets[0].id
	@AppStorage(MobileTerminalSettings.Keys.fontSize)
	private var fontSize: Double = MobileTerminalSettings.defaultFontSize
	@AppStorage(MobileTerminalSettings.Keys.defaultKeyboardNative)
	private var keyboardNative: Bool = false

	var body: some View {
		MobileSettingsContent(
			themeID: $themeID,
			fontSize: $fontSize,
			keyboardNative: $keyboardNative,
			hosts: hosts,
			snippets: snippets,
			isSynced: false
		)
	}
}

private struct MobileSyncedSettingsForm: View {
	@ObservedObject var store: SettingsStore
	var hosts: Binding<[SSHHost]>?
	var snippets: Binding<[Snippet]>?

	var body: some View {
		MobileSettingsContent(
			themeID: Binding(
				get: { store.effectiveSettings.global.theme ?? TerminalTheme.presets[0].id },
				set: { value in store.update { $0.global.theme = value } }
			),
			fontSize: Binding(
				get: {
					Double(store.effectiveSettings.global.fontSize
						?? Int(MobileTerminalSettings.defaultFontSize))
				},
				set: { value in store.update { $0.global.fontSize = Int(value) } }
			),
			keyboardNative: Binding(
				get: {
					store.effectiveSettings.global.prefersNativeMobileKeyboard
						?? false
				},
				set: { value in
					store.update { $0.global.prefersNativeMobileKeyboard = value }
				}
			),
			hosts: hosts,
			snippets: snippets,
			isSynced: true
		)
	}
}

private struct MobileSettingsContent: View {
	@Binding var themeID: String
	@Binding var fontSize: Double
	@Binding var keyboardNative: Bool
	var hosts: Binding<[SSHHost]>?
	var snippets: Binding<[Snippet]>?
	let isSynced: Bool

	private var knownThemeIDs: Set<String> {
		Set(TerminalTheme.presets.map(\.id))
	}

	var body: some View {
		Form {
			Section {
				Picker("Theme", selection: $themeID) {
					if !knownThemeIDs.contains(themeID) {
						Text("\(themeID) (Mac only)").tag(themeID)
					}
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
				Label("Hosts and snippets persist locally for offline use.",
					systemImage: "externaldrive")
				Label("Host secrets are saved to the device keychain.",
					systemImage: "key")
				if isSynced {
					Label("Hosts, snippets, and shared settings sync through iCloud.",
						systemImage: "icloud")
				} else {
					Label("iCloud sync is unavailable in this build.",
						systemImage: "icloud.slash")
				}
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
