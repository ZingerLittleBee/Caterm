import Foundation

/// A user-saved bookmark for a remote path on a particular host. Used by the
/// SFTP file drawer's "Bookmarks" popover so the user can jump back to common
/// directories (`~`, `~/projects`, `/var/log`, ...) without retyping them.
///
/// `path` is stored verbatim — `~` is a remote-shell concept and we do not
/// expand it against the local user. Path normalization (`normalizeRemotePath`)
/// is lexical-only and is used solely as a dedup key.
public struct RemoteBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var path: String
    public var createdAt: Date

    public init(id: UUID = UUID(), label: String, path: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.path = path
        self.createdAt = createdAt
    }
}

/// Lexical-only normalization of a remote path, used as a dedup key.
///
/// - Trims surrounding whitespace.
/// - Collapses runs of `/` to a single `/`.
/// - Strips a single trailing `/` (except when the whole path is `/`).
/// - Preserves `~`, `~user`, and relative paths verbatim — we do NOT expand
///   `~` against the local user (that would silently collapse `~/foo` and
///   `/Users/<localuser>/foo` into the same key, which is wrong because the
///   bookmark belongs to the remote host).
public func normalizeRemotePath(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return trimmed }

    var collapsed = ""
    var lastWasSlash = false
    for char in trimmed {
        if char == "/" {
            if !lastWasSlash { collapsed.append(char) }
            lastWasSlash = true
        } else {
            collapsed.append(char)
            lastWasSlash = false
        }
    }

    if collapsed.count > 1, collapsed.hasSuffix("/") {
        collapsed.removeLast()
    }
    return collapsed
}

private struct RemoteBookmarkFile: Codable {
    let version: Int
    let bookmarks: [RemoteBookmark]
}

/// Per-host JSON store for remote-path bookmarks.
///
/// Layout: `<directory>/<hostId>.json` per host, shape
/// `{"version": 1, "bookmarks": [...]}`.
///
/// Schema migration policy:
/// - `version <= currentVersion` → load and use.
/// - `version > currentVersion` → read-only **quarantine**: in-memory list is
///   empty, `isQuarantined(for:)` is true, all mutations are no-ops, and the
///   on-disk file is left untouched. This prevents an older build from
///   stomping on a future-schema blob written by a newer build.
/// - Garbage / undecodable JSON → recover to empty list and rename the
///   bad file to `<hostId>.json.broken-<unix-ms>` so the user can recover it
///   manually if they care.
@MainActor
public final class RemoteBookmarkStore: ObservableObject {
    public static let currentVersion = 1

    private let directory: URL
    private var cache: [UUID: [RemoteBookmark]] = [:]
    private var quarantined: Set<UUID> = []
    private var loaded: Set<UUID> = []

    public init(directory: URL) {
        self.directory = directory
    }

    public func bookmarks(for hostId: UUID) -> [RemoteBookmark] {
        loadIfNeeded(hostId)
        return cache[hostId] ?? []
    }

    public func isQuarantined(for hostId: UUID) -> Bool {
        loadIfNeeded(hostId)
        return quarantined.contains(hostId)
    }

    /// Append a bookmark. Returns `false` if the host is quarantined or if a
    /// bookmark with the same normalized path already exists (first-write
    /// wins — the existing entry's label is preserved).
    @discardableResult
    public func add(_ bookmark: RemoteBookmark, for hostId: UUID) -> Bool {
        loadIfNeeded(hostId)
        if quarantined.contains(hostId) { return false }

        var list = cache[hostId] ?? []
        let key = normalizeRemotePath(bookmark.path)
        if list.contains(where: { normalizeRemotePath($0.path) == key }) {
            return false
        }
        list.append(bookmark)
        cache[hostId] = list
        save(hostId)
        return true
    }

    public func remove(id: UUID, for hostId: UUID) {
        loadIfNeeded(hostId)
        if quarantined.contains(hostId) { return }

        var list = cache[hostId] ?? []
        list.removeAll { $0.id == id }
        cache[hostId] = list
        save(hostId)
    }

    /// Move a bookmark using `Array.move(fromOffsets:toOffset:)` semantics:
    /// the element at `from` is placed *before* whatever currently sits at
    /// `to`. Re-implemented locally to keep this module SwiftUI-free.
    public func move(from: Int, to: Int, for hostId: UUID) {
        loadIfNeeded(hostId)
        if quarantined.contains(hostId) { return }

        var list = cache[hostId] ?? []
        guard from >= 0, from < list.count, to >= 0, to <= list.count, from != to else { return }
        let element = list.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        list.insert(element, at: insertAt)
        cache[hostId] = list
        save(hostId)
    }

    // MARK: - Private

    private func loadIfNeeded(_ hostId: UUID) {
        if loaded.contains(hostId) { return }
        loaded.insert(hostId)
        cache[hostId] = []

        let url = fileURL(for: hostId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return
        }

        do {
            let file = try JSONDecoder().decode(RemoteBookmarkFile.self, from: data)
            if file.version > Self.currentVersion {
                quarantined.insert(hostId)
                return
            }
            cache[hostId] = file.bookmarks
        } catch {
            quarantineToSidecar(url: url)
        }
    }

    private func quarantineToSidecar(url: URL) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let sidecar = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).broken-\(ts)")
        try? FileManager.default.moveItem(at: url, to: sidecar)
    }

    private func save(_ hostId: UUID) {
        if quarantined.contains(hostId) { return }
        let list = cache[hostId] ?? []
        let file = RemoteBookmarkFile(version: Self.currentVersion, bookmarks: list)
        let url = fileURL(for: hostId)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Best-effort save; in practice this only fails if the directory
            // becomes unwritable mid-session, which we surface elsewhere.
        }
    }

    private func fileURL(for hostId: UUID) -> URL {
        directory.appendingPathComponent("\(hostId.uuidString).json")
    }
}
