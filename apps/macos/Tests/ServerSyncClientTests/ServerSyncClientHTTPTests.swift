import XCTest
@testable import ServerSyncClient

final class ServerSyncClientHTTPTests: XCTestCase {
	var client: URLSessionServerSyncClient!

	override func setUp() {
		MockURLProtocol.reset()
		let cfg = URLSessionConfiguration.ephemeral
		cfg.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: cfg)
		client = URLSessionServerSyncClient(
			baseURL: URL(string: "https://api.example.com")!,
			session: session
		)
	}

	func testListSendsCorrectURLAndBody() async throws {
		MockURLProtocol.handler = { _ in
			let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/api/rpc/sshHost/list")!,
				statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (resp, Data(#"{"json":[]}"#.utf8))
		}
		_ = try await client.listHosts()
		XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
		let req = MockURLProtocol.capturedRequests[0]
		XCTAssertEqual(req.url?.path, "/api/rpc/sshHost/list")
		XCTAssertEqual(req.httpMethod, "POST")
		XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
		XCTAssertEqual(MockURLProtocol.capturedBodies[0], Data(#"{"json":{}}"#.utf8))
	}

	func testListReturnsDecodedHosts() async throws {
		MockURLProtocol.handler = { _ in
			let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/api/rpc/sshHost/list")!,
				statusCode: 200, httpVersion: nil, headerFields: nil)!
			let body = #"""
			{"json":[{"id":"srv-1","name":"a","hostname":"h","port":22,"username":"u","authType":"key","createdAt":"2026-04-28T10:00:00.000Z","updatedAt":"2026-04-28T10:00:00.000Z"}]}
			"""#
			return (resp, Data(body.utf8))
		}
		let hosts = try await client.listHosts()
		XCTAssertEqual(hosts.count, 1)
		XCTAssertEqual(hosts[0].id, "srv-1")
	}

	func testListThrowsOnUnauthorized() async {
		MockURLProtocol.handler = { _ in
			let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/api/rpc/sshHost/list")!,
				statusCode: 401, httpVersion: nil, headerFields: nil)!
			return (resp, Data(#"""
			{"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"Unauthorized"}}
			"""#.utf8))
		}
		do {
			_ = try await client.listHosts()
			XCTFail("expected throw")
		} catch let ServerSyncError.orpc(code, status, _) {
			XCTAssertEqual(code, "UNAUTHORIZED")
			XCTAssertEqual(status, 401)
		} catch { XCTFail("wrong error: \(error)") }
	}

	func testCreateSendsAuthTypeKey() async throws {
		MockURLProtocol.handler = { _ in
			let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/api/rpc/sshHost/create")!,
				statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (resp, Data(#"{"json":{"id":"srv-new"}}"#.utf8))
		}
		let out = try await client.createHost(RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u"))
		XCTAssertEqual(out.id, "srv-new")
		let bodyStr = String(data: MockURLProtocol.capturedBodies[0], encoding: .utf8)!
		XCTAssertTrue(bodyStr.contains("\"authType\":\"key\""))
		XCTAssertFalse(bodyStr.contains("password"))
	}

	func testDeleteSendsId() async throws {
		MockURLProtocol.handler = { _ in
			let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/api/rpc/sshHost/delete")!,
				statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (resp, Data(#"{"json":{"success":true}}"#.utf8))
		}
		try await client.deleteHost(id: "srv-1")
		let bodyStr = String(data: MockURLProtocol.capturedBodies[0], encoding: .utf8)!
		XCTAssertEqual(bodyStr, #"{"json":{"id":"srv-1"}}"#)
	}
}
