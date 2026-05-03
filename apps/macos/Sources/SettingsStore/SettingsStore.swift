import Foundation
import Combine
import CryptoKit

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: CatermSettings
    public let path: URL

    public static let changeNotification = Notification.Name("catermSettingsChanged")
    public static let scopeUserInfoKey = "scope"
    public static let sourceUserInfoKey = "source"  // values: "local" (default) or "sync"

    /// Production location of the user's settings plist. Tests use a temp path
    /// instead (see `BootSequence.run(settingsPlistURL:...)`).
    public static var defaultPlistPath: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm/settings.plist")
    }

    // Storage for Task 9 (debounce). Declared here because Swift extensions
    // can't add stored properties and SettingsStore isn't NSObject so the
    // associated-object trick from the plan doesn't apply.
    public var debounceInterval: Duration = .milliseconds(200)

    final class _Pending {
        var settings: CatermSettings
        var task: Task<Void, Never>?
        init(_ s: CatermSettings) { self.settings = s }
    }
    var _pending: _Pending?

    public init(settings: CatermSettings, path: URL) {
        self.settings = settings
        self.path = path
    }

    public static func load(from path: URL) throws -> SettingsStore {
        if !FileManager.default.fileExists(atPath: path.path) {
            var seeded = CatermSettings.empty
            seeded.global = CatermSettings.defaultsSeed
            seeded.revision = makeRevision()
            seeded.seededByDefault = true
            seeded.seedVersion = 1
            seeded.canonicalSeedHash = v1DefaultSeedHash
            seeded.firstUserEditedAt = nil
            return SettingsStore(settings: seeded, path: path)
        }
        do {
            let data = try Data(contentsOf: path)
            var s = try PropertyListDecoder().decode(CatermSettings.self, from: data)
            if s.version < 2 {
                migrateV1ToV2(&s)
            }
            return SettingsStore(settings: s, path: path)
        } catch {
            try quarantineCorrupted(at: path)
            var seeded = CatermSettings.empty
            seeded.global = CatermSettings.defaultsSeed
            seeded.revision = makeRevision()
            seeded.seededByDefault = true
            seeded.seedVersion = 1
            seeded.canonicalSeedHash = v1DefaultSeedHash
            seeded.firstUserEditedAt = nil
            return SettingsStore(settings: seeded, path: path)
        }
    }

    private static func migrateV1ToV2(_ s: inout CatermSettings) {
        s.version = 2
        let exactDefaults = canonicalHash(of: s.global) == v1DefaultSeedHash
            && s.hostOverrides.isEmpty
        if exactDefaults {
            s.seededByDefault = true
            s.firstUserEditedAt = nil
            s.seedVersion = 1
            s.canonicalSeedHash = v1DefaultSeedHash
        } else {
            s.seededByDefault = false
            s.firstUserEditedAt = Date()  // sentinel: edited before tracking, exact moment unknown
            s.seedVersion = 1  // origin seed version; content was user-edited so canonicalSeedHash is empty
            s.canonicalSeedHash = ""  // empty never matches KnownSeedTable; locks user in real-edits
        }
    }

    public func save(_ next: CatermSettings) throws {
        var copy = next
        copy.revision = Self.makeRevision()
        let data = try PropertyListEncoder().encode(copy)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path, options: .atomic)
        self.settings = copy
    }

    private static func quarantineCorrupted(at path: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).broken-\(stamp)")
        try FileManager.default.moveItem(at: path, to: dest)
    }

    // Intentionally duplicated from KnownSeedTable.canonicalHash. SettingsStore must
    // not import SettingsSyncStore (wrong dependency direction); both implementations
    // are kept identical so v1DefaultSeedHash matches KnownSeedTable.entries[0].canonicalSeedHash.
    private static func canonicalHash(of partial: PartialSettings) -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(partial) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let v1DefaultSeedHash: String = canonicalHash(of: CatermSettings.defaultsSeed)

    public static func makeRevision() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = (0..<8).map { _ in
            "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()!
        }
        return String(ms, radix: 36) + String(rand)
    }

    public func update(_ mutate: (inout CatermSettings) -> Void) {
        var draft = _pending?.settings ?? settings
        mutate(&draft)
        if draft.firstUserEditedAt == nil {
            draft.firstUserEditedAt = Date()
        }
        let pending = _pending ?? _Pending(draft)
        pending.settings = draft
        pending.task?.cancel()
        let interval = self.debounceInterval
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushNow() }
        }
        _pending = pending
    }

    public func flushNow() {
        guard let pending = _pending else { return }
        _pending = nil
        let old = settings
        let next = pending.settings
        do {
            try save(next)
        } catch {
            NSLog("[SettingsStore] save failed: \(error)")
            return
        }
        if let scope = SettingsChangeScope.diff(old: old, new: next) {
            NotificationCenter.default.post(
                name: Self.changeNotification,
                object: self,
                userInfo: [
                    Self.scopeUserInfoKey: scope,
                    Self.sourceUserInfoKey: "local",
                ]
            )
        }
    }

    /// Sync-side cloud-apply path. Preserves cloud's revision verbatim (does NOT
    /// call makeRevision), preserves the local migrationsCompleted set, and posts
    /// a change notification tagged source == "sync" so SettingsSyncStore can
    /// filter and avoid an apply→push feedback loop.
    ///
    /// `migrationsCompleted` is per-device filesystem migration state and never
    /// travels — even though `cloud.migrationsCompleted` may have content (it
    /// shouldn't if the codec strips it correctly, but we defend at the seam).
    public func replaceFromSync(_ cloud: CatermSettings) throws {
        var next = cloud
        next.migrationsCompleted = settings.migrationsCompleted
        let data = try PropertyListEncoder().encode(next)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path, options: .atomic)
        let old = settings
        self.settings = next

        let scope = SettingsChangeScope.diff(old: old, new: next)
        var userInfo: [AnyHashable: Any] = [Self.sourceUserInfoKey: "sync"]
        if let scope = scope {
            userInfo[Self.scopeUserInfoKey] = scope
        }
        NotificationCenter.default.post(
            name: Self.changeNotification, object: self, userInfo: userInfo
        )
    }
}
