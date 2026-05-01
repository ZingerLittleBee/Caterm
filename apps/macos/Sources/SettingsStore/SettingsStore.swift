import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: CatermSettings
    public let path: URL

    public static let changeNotification = Notification.Name("catermSettingsChanged")
    public static let scopeUserInfoKey = "scope"

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
            return SettingsStore(settings: seeded, path: path)
        }
        do {
            let data = try Data(contentsOf: path)
            let s = try PropertyListDecoder().decode(CatermSettings.self, from: data)
            return SettingsStore(settings: s, path: path)
        } catch {
            try quarantineCorrupted(at: path)
            var seeded = CatermSettings.empty
            seeded.global = CatermSettings.defaultsSeed
            seeded.revision = makeRevision()
            return SettingsStore(settings: seeded, path: path)
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
                userInfo: [Self.scopeUserInfoKey: scope]
            )
        }
    }
}
