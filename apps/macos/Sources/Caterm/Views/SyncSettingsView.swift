import HostSyncStore
import ServerSyncClient
import SwiftUI

struct SyncSettingsView: View {
    let authSession: AuthSession
    let syncStore: HostSyncStore
    @Binding var serverURL: String
    @State private var isSigningOut = false
    @State private var isSyncing = false
    @State private var lastSyncError: String?
    @State private var showSignIn = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL)
                    .disableAutocorrection(true)
                Text("Restart Caterm after changing the server URL.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Account") {
                if authSession.isSignedIn {
                    Button("Sign Out") { Task { await signOut() } }
                        .disabled(isSigningOut)
                } else {
                    Button("Sign In…") { showSignIn = true }
                }
            }
            Section("Sync") {
                Button("Sync Now") { Task { await syncNow() } }
                    .disabled(!authSession.isSignedIn || isSyncing)
                if let lastSyncError {
                    Text(lastSyncError).foregroundColor(.red).font(.caption)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(isPresented: $showSignIn) {
            SignInView(authSession: authSession, onSignedIn: {
                showSignIn = false
            })
        }
    }

    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        try? await authSession.signOut()
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        lastSyncError = nil
        do {
            try await syncStore.sync()
        } catch {
            lastSyncError = "\(error)"
        }
    }
}
