import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import SessionStore
import SwiftUI

struct CredentialSyncSection: View {
	@ObservedObject var prefsStore: CredentialSyncPreferencesStore
	let coordinator: CredentialSyncCoordinator
	@ObservedObject var sessionStore: SessionStore
	let triggerSync: () -> Void

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
							credentialSync: prefsStore,
							triggerSync: triggerSync
						)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("This removes credentials from iCloud for ALL your devices. Each device keeps its local credentials. To repopulate iCloud from this Mac, edit any host afterward.")
				}
			}
			corruptList
		}
	}

	@ViewBuilder
	private var statusLine: some View {
		switch prefsStore.prefs.state {
		case .enabled:
			Text(enabledStatusText)
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

	/// Visibility for the destructive "Delete from iCloud" button. Hidden when
	/// the destructive flow has already cleared cloud (only tombstones remain),
	/// or when no host has ever pushed a payload from this device.
	private var hasPayload: Bool {
		guard case .enabled = prefsStore.prefs.state else { return false }
		if prefsStore.prefs.cloudCredentialsCleared { return false }
		return payloadCount > 0
	}

	/// Hosts whose cloud blob is, from this device's last-known view, a
	/// payload (not a tombstone). Filtered by current local hosts so a host
	/// deleted locally stops counting even before its CloudKit record is
	/// reconciled. Driven by `prefsStore.prefs.hostsWithCloudPayload`,
	/// updated by HostSyncStore on every push (payload→insert, tombstone→
	/// remove) and pull (decrypt success→insert, observed tombstone→remove).
	private var payloadCount: Int {
		let payloadSet = prefsStore.prefs.hostsWithCloudPayload
		return sessionStore.hosts.filter { payloadSet.contains($0.id) }.count
	}

	/// `state == .enabled` status copy. Distinguishes three sub-states:
	///   - destructive flow in progress      — "Removing credentials from iCloud…"
	///   - destructive flow finished + cleared — "Cloud cleared. Edit any host to repopulate."
	///   - normal                              — "N hosts synced…" / "Edit any host to populate"
	private var enabledStatusText: String {
		if prefsStore.prefs.deleteCredentialsFromCloudInProgress != nil {
			return "Removing credentials from iCloud…"
		}
		if prefsStore.prefs.cloudCredentialsCleared {
			return "iCloud credentials cleared. Edit any host to repopulate."
		}
		if payloadCount > 0 {
			return "\(payloadCount) hosts synced; encrypted with a key only your devices can read"
		}
		return "Credential sync enabled. Edit any host to populate iCloud."
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
