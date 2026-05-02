import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import SessionStore
import SwiftUI

struct CredentialSyncSection: View {
	@ObservedObject var prefsStore: CredentialSyncPreferencesStore
	let coordinator: CredentialSyncCoordinator
	@ObservedObject var sessionStore: SessionStore

	@State private var confirmingDelete = false
	@State private var enableError: String?

	private var isOn: Binding<Bool> {
		Binding(
			get: {
				if case .enabled = prefsStore.prefs.state { return true }
				return false
			},
			set: { newValue in
				Task { await handleToggle(newValue) }
			}
		)
	}

	var body: some View {
		Section("Credential Sync (Beta)") {
			Toggle("Sync SSH credentials on this Mac", isOn: isOn)
				.disabled(prefsStore.prefs.deleteCredentialsFromCloudInProgress != nil)
			if let err = enableError {
				Text(err).font(.caption).foregroundColor(.red)
			}
			statusLine
			if hasPayload {
				Button("Delete synced credentials from iCloud…", role: .destructive) {
					confirmingDelete = true
				}
				.confirmationDialog(
					"Delete synced credentials from iCloud?",
					isPresented: $confirmingDelete
				) {
					Button("Delete", role: .destructive) {
						DestructiveDeletionFlow.confirm(
							sessionStore: sessionStore,
							credentialSync: prefsStore
						)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("This removes credentials from iCloud for ALL your devices. Each device keeps its local credentials. To re-enable sync afterward, enable the toggle on a device of your choice.")
				}
			}
			corruptList
		}
	}

	@ViewBuilder
	private var statusLine: some View {
		switch prefsStore.prefs.state {
		case .enabled:
			Text(payloadCount > 0
				? "\(payloadCount) hosts synced; encrypted with a key only your devices can read"
				: "Credential sync enabled. Edit any host to populate iCloud.")
				.font(.caption).foregroundColor(.secondary)
		case .waitingForKey:
			HStack {
				Text("Waiting for iCloud Keychain to deliver the encryption key from another device…")
					.font(.caption).foregroundColor(.secondary)
				Button("Retry") {
					Task { await coordinator.reconcileMasterKeyArrival() }
				}
			}
		case .pausedByRemote:
			Text("Credential sync was disabled across your devices. Toggle off then on to re-pull from iCloud.")
				.font(.caption).foregroundColor(.secondary)
		case .disabled:
			EmptyView()
		}
	}

	@ViewBuilder
	private var corruptList: some View {
		let corruptHostIds = Set(prefsStore.prefs.corruptCredentials.map(\.hostId))
		if !corruptHostIds.isEmpty {
			VStack(alignment: .leading) {
				Text("Couldn't decrypt credentials for these hosts:")
					.font(.caption).foregroundColor(.orange)
				ForEach(sessionStore.hosts.filter { corruptHostIds.contains($0.id) }) { h in
					Text("• \(h.name)").font(.caption)
				}
				Text("Re-enter the credential locally to resolve.")
					.font(.caption2).foregroundColor(.secondary)
			}
		}
	}

	private var hasPayload: Bool {
		if case .enabled = prefsStore.prefs.state { return payloadCount > 0 }
		return false
	}

	private var payloadCount: Int {
		sessionStore.hosts.filter {
			$0.serverId != nil && (prefsStore.prefs.lastAppliedRevision[$0.id] ?? 0) > 0
		}.count
	}

	private func handleToggle(_ newValue: Bool) async {
		if newValue {
			do {
				try await coordinator.enable()
				enableError = nil
			} catch {
				enableError = "Enable iCloud Keychain in System Settings → Apple ID → iCloud → Passwords & Keychain"
			}
		} else {
			coordinator.disable()
			enableError = nil
		}
	}
}
