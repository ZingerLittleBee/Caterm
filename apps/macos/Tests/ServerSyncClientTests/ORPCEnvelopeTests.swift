import XCTest
@testable import ServerSyncClient

final class ORPCEnvelopeTests: XCTestCase {
    func testEncodesEmptyInputAsJSONNull() throws {
        let envelope = ORPCEnvelope<EmptyInput>(json: EmptyInput())
        let data = try JSONEncoder().encode(envelope)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str, #"{"json":{}}"#)
    }

    func testDecodesSuccessEnvelope() throws {
        struct Out: Decodable, Equatable { let id: String }
        let json = #"{"json":{"id":"srv-1"}}"#
        let env = try JSONDecoder().decode(ORPCEnvelope<Out>.self, from: Data(json.utf8))
        XCTAssertEqual(env.json, Out(id: "srv-1"))
    }

    func testDecodesErrorEnvelopeAsThrow() throws {
        let json = #"""
        {"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"Unauthorized"}}
        """#
        XCTAssertThrowsError(try parseORPCResponse(Data(json.utf8), as: String.self)) { err in
            guard case let ServerSyncError.orpc(code, status, message) = err else {
                return XCTFail("expected .orpc, got \(err)")
            }
            XCTAssertEqual(code, "UNAUTHORIZED")
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Unauthorized")
        }
    }
}
