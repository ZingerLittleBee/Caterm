import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class KnownSeedTableTests: XCTestCase {
    func test_canonicalHash_isStableAcrossInvocations() {
        let h1 = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        let h2 = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        XCTAssertEqual(h1, h2)
        XCTAssertFalse(h1.isEmpty)
    }

    func test_canonicalHash_differsForDifferentValues() {
        var modified = CatermSettings.defaultsSeed
        modified.fontSize = 42
        XCTAssertNotEqual(
            KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed),
            KnownSeedTable.canonicalHash(of: modified)
        )
    }

    func test_currentSeed_isInTheTable() {
        let entry = KnownSeedTable.entries.first { $0.canonicalSeedHash ==
            KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed) }
        XCTAssertNotNil(entry, "current default seed must be registered in the table")
        XCTAssertGreaterThan(entry!.seedVersion, 0)
    }

    func test_versions_areAppendOnlyMonotonic() {
        let versions = KnownSeedTable.entries.map(\.seedVersion)
        XCTAssertEqual(versions, versions.sorted(), "entries must be append-only sorted")
        XCTAssertEqual(Set(versions).count, versions.count, "no duplicate versions")
    }
}
