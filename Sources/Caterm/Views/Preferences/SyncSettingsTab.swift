import CredentialSync
import CredentialSyncStore
import HostSyncStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SnippetStore
import SwiftUI

/// Wrapper view that adapts `SyncSettingsView` so it can be embedded as a
/// Preferences tab without changes to its public signature.
///
/// The wrapper exists because `SyncSettingsView` requires
/// `AuthSessionProtocol` (a non-`ObservableObject` reference type) plus two
/// `ObservableObject`s; threading those through `PreferencesTab.viewBuilder`
/// would force every tab builder to know about sync. The Preferences window
/// controller holds the trio as a tuple and passes it explicitly here.
struct SyncSettingsTab: View {
    let authSession: AuthSessionProtocol
    @ObservedObject var syncStore: HostSyncStore
    @ObservedObject var preferences: SyncPreferences
    let credentialSync: CredentialSyncPreferencesStore?
    let credentialSyncCoordinator: CredentialSyncCoordinator?
    let sessionStore: SessionStore?
    let managedKeyStore: ManagedKeyStore?
    let snippetStore: SnippetStore?
    let bookmarkStore: RemoteBookmarkStore?

    init(
        authSession: AuthSessionProtocol,
        syncStore: HostSyncStore,
        preferences: SyncPreferences,
        credentialSync: CredentialSyncPreferencesStore? = nil,
        credentialSyncCoordinator: CredentialSyncCoordinator? = nil,
        sessionStore: SessionStore? = nil,
        managedKeyStore: ManagedKeyStore? = nil,
        snippetStore: SnippetStore? = nil,
        bookmarkStore: RemoteBookmarkStore? = nil
    ) {
        self.authSession = authSession
        self.syncStore = syncStore
        self.preferences = preferences
        self.credentialSync = credentialSync
        self.credentialSyncCoordinator = credentialSyncCoordinator
        self.sessionStore = sessionStore
        self.managedKeyStore = managedKeyStore
        self.snippetStore = snippetStore
        self.bookmarkStore = bookmarkStore
    }

    var body: some View {
        SyncSettingsView(
            authSession: authSession,
            syncStore: syncStore,
            preferences: preferences,
            credentialSync: credentialSync,
            credentialSyncCoordinator: credentialSyncCoordinator,
            sessionStore: sessionStore,
            managedKeyStore: managedKeyStore,
            snippetStore: snippetStore,
            bookmarkStore: bookmarkStore
        )
    }
}
