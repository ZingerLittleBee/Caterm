import Foundation

struct SpikeConfig: Codable {
    let host: String
    let port: Int
    let user: String
    /// Password is only used by `sshpass` (set via env). The spike doesn't ship
    /// a Keychain integration. Real Phase 1 uses ssh-agent / Keychain askpass.
    let password: String?

    static func load() throws -> SpikeConfig {
        let env = ProcessInfo.processInfo.environment
        if let h = env["CATERM_SPIKE_HOST"],
           let u = env["CATERM_SPIKE_USER"] {
            let port = Int(env["CATERM_SPIKE_PORT"] ?? "22") ?? 22
            return SpikeConfig(
                host: h,
                port: port,
                user: u,
                password: env["CATERM_SPIKE_PASSWORD"]
            )
        }

        let candidates = [
            URL(fileURLWithPath: "apps/macos/.spike.local.json",
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
            URL(fileURLWithPath: ".spike.local.json",
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SpikeConfig.self, from: data)
        }

        throw NSError(domain: "SpikeConfig", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "No config found. Set CATERM_SPIKE_HOST/USER (and PORT/PASSWORD) env vars or create apps/macos/.spike.local.json"
        ])
    }

    /// Builds the command libghostty's surface should spawn. We rely on the
    /// system `/usr/bin/ssh` so libghostty owns the PTY and we get auth /
    /// host-key handling for free via `~/.ssh/config` and the user's agent.
    /// Password (if set) is forwarded via `sshpass` for the spike — Phase 1
    /// drops this in favor of agent / Keychain askpass.
    func sshCommand() -> String {
        // -o StrictHostKeyChecking=accept-new accepts new host keys on first
        // connect (TOFU) without blocking. -o UserKnownHostsFile points at a
        // throwaway file so the spike doesn't pollute ~/.ssh/known_hosts.
        let sshArgs = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=/tmp/caterm-spike-known_hosts",
            "-p", "\(port)",
            "\(user)@\(host)"
        ].joined(separator: " ")

        if let password, !password.isEmpty {
            return "/usr/bin/env SSHPASS=\(shellQuote(password)) sshpass -e /usr/bin/ssh \(sshArgs)"
        }
        return "/usr/bin/ssh \(sshArgs)"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
