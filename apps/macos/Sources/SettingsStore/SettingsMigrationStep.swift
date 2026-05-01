import CryptoKit
import Foundation

public enum SettingsMigrationResult: Equatable {
    case branchA
    case branchB(representable: Int, unrepresentable: Int)
    case branchC
    case alreadyCompleted
}

public enum SettingsMigrationError: Error {
    case backupFailed(underlying: Error)
}

public enum SettingsMigrationStep {
    public static let token = "settings-gui-v1"

    /// Exact bytes of the legacy seed in `ConfigStore.defaultConfig`. Used as the
    /// fingerprint check; future Caterm releases append additional historical defaults.
    public static let legacyDefaultV1 = """
        # Caterm-managed Ghostty config — edit freely, restart Caterm to apply.
        # Full reference: https://ghostty.org/docs/config

        font-family = SF Mono
        font-size = 13
        theme = Catppuccin Mocha
        cursor-style = block
        macos-titlebar-style = tabs
        """

    public static let legacyFingerprints: [String] = [
        sha256(legacyDefaultV1),
    ]

    public static let placeholderUserConfig = """
        # User overrides for Caterm. Anything you put here wins over the
        # Caterm-managed config. Use Caterm Preferences (⌘,) for normal settings.
        """

    @MainActor
    public static func runIfNeeded(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws -> SettingsMigrationResult {
        if settings.migrationsCompleted.contains(token) {
            return .alreadyCompleted
        }

        if !FileManager.default.fileExists(atPath: userConfigPath.path) {
            try seedDefaultsAndWritePlaceholder(userConfigPath: userConfigPath, settings: &settings)
            settings.migrationsCompleted.insert(token)
            return .branchC
        }

        let raw = (try? String(contentsOf: userConfigPath, encoding: .utf8)) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let fingerprint = sha256(trimmed)

        if legacyFingerprints.contains(fingerprint) {
            try backupUserConfig(at: userConfigPath)
            applyLegacyDefaultsToSettings(&settings)
            try placeholderUserConfig.write(to: userConfigPath, atomically: true, encoding: .utf8)
            settings.migrationsCompleted.insert(token)
            return .branchA
        }

        // Branch B — implemented in Task 14
        let summary = try runBranchB(userConfigPath: userConfigPath, settings: &settings)
        settings.migrationsCompleted.insert(token)
        return .branchB(representable: summary.representableCount, unrepresentable: summary.unrepresentableCount)
    }

    private static func seedDefaultsAndWritePlaceholder(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws {
        if settings.global == PartialSettings() {
            settings.global = CatermSettings.defaultsSeed
        }
        try FileManager.default.createDirectory(
            at: userConfigPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try placeholderUserConfig.write(to: userConfigPath, atomically: true, encoding: .utf8)
    }

    private static func applyLegacyDefaultsToSettings(_ settings: inout CatermSettings) {
        settings.global = CatermSettings.defaultsSeed
    }

    private static func backupUserConfig(at path: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).bak-pre-settings-gui-\(stamp)")
        do {
            try FileManager.default.copyItem(at: path, to: backup)
        } catch {
            throw SettingsMigrationError.backupFailed(underlying: error)
        }
    }

    private static func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        let h = SHA256.hash(data: data)
        return h.map { String(format: "%02x", $0) }.joined()
    }
}

internal extension SettingsMigrationStep {
    struct BranchBSummary {
        let representableCount: Int
        let unrepresentableCount: Int
    }

    @MainActor
    static func runBranchB(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws -> BranchBSummary {
        // Stub — overwritten in Task 15.
        return BranchBSummary(representableCount: 0, unrepresentableCount: 0)
    }
}
