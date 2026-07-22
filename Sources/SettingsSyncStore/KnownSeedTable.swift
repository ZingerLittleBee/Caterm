import CryptoKit
import Foundation
import SettingsStore

/// Append-only table of every default seed shipped historically. Old entries
/// are NEVER deleted: when `CatermSettings.defaultsSeed` changes, append a new
/// entry. Older devices' canonical hashes still map to a known seed version,
/// so the `IsDefaultSeedUnedited` predicate can recognize them.
public enum KnownSeedTable {
    public struct Entry: Equatable {
        public let seedVersion: Int
        public let snapshot: PartialSettings
        public let canonicalSeedHash: String
    }

    public static let entries: [Entry] = {
        var table: [Entry] = []
        // v1 — original Plan D rollout. NEVER mutate this entry.
        let v1 = PartialSettings(
            fontFamily: "SF Mono",
            fontSize: 13,
            cursorStyle: .block,
            scrollbackBytes: 10_000_000,
            titlebarStyle: .tabs,
            theme: "Catppuccin Mocha"
        )
        table.append(Entry(seedVersion: 1, snapshot: v1))
        return table
    }()

    public static var versions: Set<Int> { Set(entries.map(\.seedVersion)) }
    public static var hashes: Set<String> { Set(entries.map(\.canonicalSeedHash)) }

    public static func entry(forVersion v: Int) -> Entry? {
        entries.first { $0.seedVersion == v }
    }

    /// Canonical SHA-256 of a `PartialSettings`. Binary plist format is used
    /// because it produces a compact, deterministic byte sequence. Known
    /// fields use stable coding keys; opaque future fields participate only
    /// when they are actually present.
    public static func canonicalHash(of partial: PartialSettings) -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(partial) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension KnownSeedTable.Entry {
    /// Convenience initializer that derives `canonicalSeedHash` from the snapshot.
    /// Use this when adding entries to the table to avoid manually computing
    /// or copy-pasting hashes.
    public init(seedVersion: Int, snapshot: PartialSettings) {
        self.init(
            seedVersion: seedVersion,
            snapshot: snapshot,
            canonicalSeedHash: KnownSeedTable.canonicalHash(of: snapshot)
        )
    }
}
