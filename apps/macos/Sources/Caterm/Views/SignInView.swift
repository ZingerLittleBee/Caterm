import ServerSyncClient
import SwiftUI

struct SignInView: View {
    let authSession: AuthSession
    var onSignedIn: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isSigningIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Caterm").font(.title2)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundColor(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Sign In") { Task { await signIn() } }
                    .disabled(email.isEmpty || password.isEmpty || isSigningIn)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        error = nil
        do {
            try await authSession.signIn(email: email, password: password)
            onSignedIn()
        } catch let ServerSyncError.authFailed(_, msg) {
            error = msg
        } catch let err {
            error = "Sign-in failed: \(err.localizedDescription)"
        }
    }
}
