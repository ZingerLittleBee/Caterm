import CredentialSync
import CredentialSyncStore
import HostSyncStore
import ServerSyncClient
import SessionStore
import SwiftUI

/// Wrapper view that adapts the existing four-property `SyncSettingsView` so
/// it can be embedded as a Preferences tab without changes to its public
/// signature. Owns the `serverURL` text-field state locally and persists
/// changes to `ServerURL` on edit.
///
/// The wrapper exists because:
/// 1. `SyncSettingsView` predates the unified Preferences window. It
///    requires `AuthSession` (a non-`ObservableObject` reference type) plus
///    two `ObservableObject`s. Threading those raw env objects through
///    `PreferencesTab.viewBuilder` would force every tab builder to know
///    about sync.
/// 2. `AuthSession` cannot be injected via `.environmentObject` — it is not
///    `ObservableObject`. The Preferences window controller therefore holds
///    the trio as a tuple and passes it explicitly to this wrapper.
struct SyncSettingsTab: View {
    let authSession: AuthSession
    @ObservedObject var syncStore: HostSyncStore
    @ObservedObject var preferences: SyncPreferences
    let credentialSync: CredentialSyncPreferencesStore?
    let credentialSyncCoordinator: CredentialSyncCoordinator?
    let sessionStore: SessionStore?
    @State private var serverURL: String = ServerURL.current.absoluteString

    init(
        authSession: AuthSession,
        syncStore: HostSyncStore,
        preferences: SyncPreferences,
        credentialSync: CredentialSyncPreferencesStore? = nil,
        credentialSyncCoordinator: CredentialSyncCoordinator? = nil,
        sessionStore: SessionStore? = nil
    ) {
        self.authSession = authSession
        self.syncStore = syncStore
        self.preferences = preferences
        self.credentialSync = credentialSync
        self.credentialSyncCoordinator = credentialSyncCoordinator
        self.sessionStore = sessionStore
    }

    var body: some View {
        SyncSettingsView(
            authSession: authSession,
            syncStore: syncStore,
            preferences: preferences,
            serverURL: $serverURL,
            credentialSync: credentialSync,
            credentialSyncCoordinator: credentialSyncCoordinator,
            sessionStore: sessionStore
        )
        .onChange(of: serverURL) { _, newValue in
            // Persist on edit. SyncSettingsView already shows the
            // "Restart Caterm after changing the server URL." hint, so we
            // simply trust the user to relaunch.
            if let parsed = URL(string: newValue) {
                ServerURL.set(parsed)
            }
        }
    }
}
