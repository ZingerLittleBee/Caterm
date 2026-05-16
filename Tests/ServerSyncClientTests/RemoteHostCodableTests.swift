import XCTest
@testable import ServerSyncClient

final class RemoteHostCodableTests: XCTestCase {
    func testDecodesServerListRow() throws {
        let json = #"""
        {
            "id": "srv-1",
            "name": "alpha",
            "hostname": "1.2.3.4",
            "port": 22,
            "username": "root",
            "authType": "key",
            "createdAt": "2026-04-28T10:00:00.000Z",
            "updatedAt": "2026-04-28T10:00:00.000Z"
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let row = try dec.decode(RemoteHost.self, from: Data(json.utf8))
        XCTAssertEqual(row.id, "srv-1")
        XCTAssertEqual(row.name, "alpha")
        XCTAssertEqual(row.port, 22)
        XCTAssertEqual(row.authType, "key")
    }

    func testLegacyRowWithoutIconDecodesAsNil() throws {
        let json = #"""
        {
            "id": "srv-1", "name": "alpha", "hostname": "1.2.3.4",
            "port": 22, "username": "root", "authType": "key",
            "createdAt": "2026-04-28T10:00:00.000Z",
            "updatedAt": "2026-04-28T10:00:00.000Z"
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let row = try dec.decode(RemoteHost.self, from: Data(json.utf8))
        XCTAssertNil(row.icon)
    }

    func testIconRoundTrips() throws {
        let original = RemoteHost(
            id: "srv-1", name: "alpha", hostname: "1.2.3.4", port: 22,
            username: "root", authType: "key",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            icon: "globe.americas.fill"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
        XCTAssertEqual(decoded.icon, "globe.americas.fill")
    }

    func testEncodesCreateInputOmitsCredentialFields() throws {
        let input = RemoteHostCreateInput(
            name: "alpha", hostname: "1.2.3.4",
            port: 22, username: "root"
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(input)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"authType\":\"key\""))
        XCTAssertFalse(str.contains("password"))
        XCTAssertFalse(str.contains("privateKey"))
        XCTAssertFalse(str.contains("keyPassphrase"))
    }
}
