import Foundation
import KeychainStore
import CatermAskpassCore

// caterm-askpass — invoked by ssh via SSH_ASKPASS=<this binary>.
//
// ssh forks-execs us with no controlling tty and expects us to write the
// password (or passphrase) to stdout. We pick the Keychain item via two env
// vars set by SSHCommandBuilder:
//   CATERM_HOST_ID    — UUID of the host
//   CATERM_ASKPASS_KIND — "password" or "keyPassphrase"
//
// Keychain account format: "<host-id>.<kind>"
// Keychain access group:   "$(TeamIdentifierPrefix)caterm.shared"
//                          (set via CATERM_ACCESS_GROUP env from main app)
//
// On success: write secret + "\n" to stdout, exit 0.
// On failure: write diagnostic to stderr, exit non-zero.

let env = ProcessInfo.processInfo.environment

// Lightweight invocation log so we can diagnose "ssh says wrong password" with
// real evidence instead of guessing. One line per invocation; logs the exit
// status, the keychain account looked up, the access group, and the secret
// length (NEVER the secret itself). File is auto-created if missing.
let logURL: URL = {
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Caterm", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent("caterm-askpass.log")
}()

func logLine(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) pid=\(getpid()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: logURL)
    }
}

// Dev-only stuff mode — used by Task 1.4 EndToEndSSHTests to seed a Keychain
// item from the same signed binary that will later read it (so the partition
// list automatically grants access without an "Always Allow" dialog). Gated
// behind an explicit env var so production ssh invocations cannot trigger it.
//
// Usage:
//   CATERM_ASKPASS_STUFF=1 \
//   CATERM_HOST_ID=<uuid> \
//   CATERM_ASKPASS_KIND=password \
//   CATERM_ASKPASS_SECRET=<secret> \
//   CATERM_ACCESS_GROUP=<optional> \
//     ./caterm-askpass
if env["CATERM_ASKPASS_STUFF"] == "1" {
    guard let hostId = env["CATERM_HOST_ID"], !hostId.isEmpty,
          let kind = env["CATERM_ASKPASS_KIND"],
          kind == "password" || kind == "keyPassphrase",
          let secret = env["CATERM_ASKPASS_SECRET"]
    else {
        FileHandle.standardError.write(Data("stuff: missing required env\n".utf8))
        exit(1)
    }
    let stuffStore = KeychainStore(service: "com.caterm.host",
                                   accessGroup: env["CATERM_ACCESS_GROUP"])
    do {
        try stuffStore.set(account: "\(hostId).\(kind)", secret: secret)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("stuff: keychain write failed \(error)\n".utf8))
        exit(4)
    }
}

// ── Chain mode ─────────────────────────────────────────────────────
// Triggered when SSHCommandBuilder set CATERM_CHAIN. The resolver
// matches argv[1] against the chain and tells us which host's
// secret to fetch. On ambiguity or unknown prompt, exit 2.
if let chainJSON = env["CATERM_CHAIN"], !chainJSON.isEmpty {
    let chain: [AskpassChainEntry]
    do {
        chain = try JSONDecoder().decode([AskpassChainEntry].self,
                                        from: Data(chainJSON.utf8))
    } catch {
        FileHandle.standardError.write(Data(
            "askpass: malformed CATERM_CHAIN: \(error)\n".utf8))
        logLine("FAIL exit=1 reason=chain-json-malformed")
        exit(1)
    }

    let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    let resolution = resolveAskpassPrompt(prompt, chain: chain)

    let hostId: String
    let kind: String
    switch resolution {
    case .found(.password(let id)):
        hostId = id
        kind = "password"
    case .found(.passphrase(let id)):
        hostId = id
        kind = "keyPassphrase"
    case .ambiguous:
        FileHandle.standardError.write(Data(
            "askpass: ambiguous chain entry for prompt: \(prompt)\n".utf8))
        logLine("FAIL exit=2 reason=chain-ambiguous prompt=\(prompt)")
        exit(2)
    case .noMatch:
        FileHandle.standardError.write(Data(
            "askpass: no chain entry matches prompt: \(prompt)\n".utf8))
        logLine("FAIL exit=2 reason=chain-no-match prompt=\(prompt)")
        exit(2)
    }

    let account = "\(hostId).\(kind)"
    let accessGroup = env["CATERM_ACCESS_GROUP"]
    let groupTag = accessGroup ?? "<nil>"
    let store = KeychainStore(service: "com.caterm.host",
                              accessGroup: accessGroup)
    do {
        let secret = try store.get(account: account)
        let out = secret + "\n"
        FileHandle.standardOutput.write(Data(out.utf8))
        logLine("OK exit=0 mode=chain account=\(account) " +
                "group=\(groupTag) secretLen=\(secret.count)")
        exit(0)
    } catch KeychainError.notFound {
        FileHandle.standardError.write(Data(
            "askpass: secret not found for \(account)\n".utf8))
        logLine("FAIL exit=2 mode=chain reason=keychain-not-found " +
                "account=\(account) group=\(groupTag)")
        exit(2)
    } catch {
        FileHandle.standardError.write(Data(
            "askpass: keychain error \(error)\n".utf8))
        logLine("FAIL exit=3 mode=chain reason=keychain-error " +
                "account=\(account) group=\(groupTag) error=\(error)")
        exit(3)
    }
}

guard let hostId = env["CATERM_HOST_ID"], !hostId.isEmpty else {
    FileHandle.standardError.write(Data("CATERM_HOST_ID not set\n".utf8))
    logLine("FAIL exit=1 reason=CATERM_HOST_ID-not-set")
    exit(1)
}
guard let kind = env["CATERM_ASKPASS_KIND"],
      kind == "password" || kind == "keyPassphrase" else {
    FileHandle.standardError.write(Data("CATERM_ASKPASS_KIND invalid\n".utf8))
    logLine("FAIL exit=1 reason=CATERM_ASKPASS_KIND-invalid host=\(hostId)")
    exit(1)
}

let account = "\(hostId).\(kind)"
let accessGroup = env["CATERM_ACCESS_GROUP"]
let groupTag = accessGroup ?? "<nil>"
let store = KeychainStore(service: "com.caterm.host", accessGroup: accessGroup)

do {
    let secret = try store.get(account: account)
    let out = secret + "\n"
    FileHandle.standardOutput.write(Data(out.utf8))
    logLine("OK exit=0 account=\(account) group=\(groupTag) secretLen=\(secret.count)")
    exit(0)
} catch KeychainError.notFound {
    FileHandle.standardError.write(Data("askpass: secret not found for \(account)\n".utf8))
    logLine("FAIL exit=2 reason=keychain-not-found account=\(account) group=\(groupTag)")
    exit(2)
} catch {
    FileHandle.standardError.write(Data("askpass: keychain error \(error)\n".utf8))
    logLine("FAIL exit=3 reason=keychain-error account=\(account) group=\(groupTag) error=\(error)")
    exit(3)
}
