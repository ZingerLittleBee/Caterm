import Foundation
import KeychainStore

// caterm-askpass — invoked by ssh via SSH_ASKPASS=<this binary>.
//
// ssh forks-execs us with no controlling tty and expects us to write the
// password (or passphrase) to stdout. We pick the Keychain item via two env
// vars set by SSHCommandBuilder:
//   CATERM_HOST_ID    — UUID of the host
//   CATERM_ASKPASS_KIND — "password" or "passphrase"
//
// Keychain account format: "<host-id>.<kind>"
// Keychain access group:   "$(TeamIdentifierPrefix)caterm.shared"
//                          (set via CATERM_ACCESS_GROUP env from main app)
//
// On success: write secret + "\n" to stdout, exit 0.
// On failure: write diagnostic to stderr, exit non-zero.

let env = ProcessInfo.processInfo.environment

guard let hostId = env["CATERM_HOST_ID"], !hostId.isEmpty else {
    FileHandle.standardError.write(Data("CATERM_HOST_ID not set\n".utf8))
    exit(1)
}
guard let kind = env["CATERM_ASKPASS_KIND"],
      kind == "password" || kind == "passphrase" else {
    FileHandle.standardError.write(Data("CATERM_ASKPASS_KIND invalid\n".utf8))
    exit(1)
}

let account = "\(hostId).\(kind)"
let accessGroup = env["CATERM_ACCESS_GROUP"]
let store = KeychainStore(service: "com.caterm.host", accessGroup: accessGroup)

do {
    let secret = try store.get(account: account)
    let out = secret + "\n"
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
} catch KeychainError.notFound {
    FileHandle.standardError.write(Data("askpass: secret not found for \(account)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("askpass: keychain error \(error)\n".utf8))
    exit(3)
}
