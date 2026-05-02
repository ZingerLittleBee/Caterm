import CryptoKit
import CredentialSyncStore
import CredentialSyncTypes
import XCTest

final class EnvelopeCryptoTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func test_sealOpenRoundTrip_password() throws {
        let aad = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let plaintext = Data("hunter2".utf8)
        let sealed = try EnvelopeCrypto.seal(plaintext, key: key, aad: aad)
        let recovered = try EnvelopeCrypto.open(sealed, key: key, aad: aad)
        XCTAssertEqual(recovered, plaintext)
    }

    func test_open_failsOnAADFieldKindMismatch() throws {
        let sealAAD = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let openAAD = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .privateKey, revision: 1)
        let sealed = try EnvelopeCrypto.seal(Data("x".utf8), key: key, aad: sealAAD)
        XCTAssertThrowsError(try EnvelopeCrypto.open(sealed, key: key, aad: openAAD))
    }

    func test_open_failsOnAADServerIdMismatch() throws {
        let sealAAD = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let openAAD = EnvelopeCrypto.aad(serverId: "rec-2", fieldKind: .password, revision: 1)
        let sealed = try EnvelopeCrypto.seal(Data("x".utf8), key: key, aad: sealAAD)
        XCTAssertThrowsError(try EnvelopeCrypto.open(sealed, key: key, aad: openAAD))
    }

    func test_open_failsOnAADRevisionMismatch() throws {
        let sealAAD = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let openAAD = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 2)
        let sealed = try EnvelopeCrypto.seal(Data("x".utf8), key: key, aad: sealAAD)
        XCTAssertThrowsError(try EnvelopeCrypto.open(sealed, key: key, aad: openAAD))
    }

    func test_open_failsOnWrongKey() throws {
        let aad = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let sealed = try EnvelopeCrypto.seal(Data("x".utf8), key: key, aad: aad)
        XCTAssertThrowsError(try EnvelopeCrypto.open(sealed, key: SymmetricKey(size: .bits256), aad: aad))
    }

    func test_seal_producesUniqueNoncesAcrossInvocations() throws {
        let aad = EnvelopeCrypto.aad(serverId: "rec-1", fieldKind: .password, revision: 1)
        let plaintext = Data("repeat".utf8)
        let s1 = try EnvelopeCrypto.seal(plaintext, key: key, aad: aad)
        let s2 = try EnvelopeCrypto.seal(plaintext, key: key, aad: aad)
        XCTAssertNotEqual(s1, s2, "AES-GCM seal must use a fresh nonce each call")
    }

    func test_aad_isStableUTF8() {
        let aad = EnvelopeCrypto.aad(serverId: "abc-DEF_123", fieldKind: .privateKey, revision: 42)
        XCTAssertEqual(aad, Data("abc-DEF_123|privateKey|42|1".utf8))
    }
}
