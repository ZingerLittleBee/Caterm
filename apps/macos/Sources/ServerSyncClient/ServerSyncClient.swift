import Foundation

/// Read/write façade for the oRPC `sshHost` router.
public protocol ServerSyncClient: Sendable {
	func listHosts() async throws -> [RemoteHost]
	func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput
	func updateHost(_ input: RemoteHostUpdateInput) async throws
	func deleteHost(id: String) async throws
}

/// URLSession-based implementation. Calls
/// `POST <baseURL>/api/rpc/<router>/<method>` with body `{"json": <input>}`.
/// Cookies (the better-auth session) are managed by the URLSession's
/// HTTPCookieStorage; the caller wires up cookie persistence via the
/// session configuration.
public final class URLSessionServerSyncClient: ServerSyncClient {
	private let baseURL: URL
	private let session: URLSession
	private let encoder: JSONEncoder
	private let decoder: JSONDecoder

	public init(baseURL: URL, session: URLSession = .shared) {
		self.baseURL = baseURL
		self.session = session
		self.encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		self.decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
	}

	public func listHosts() async throws -> [RemoteHost] {
		try await rpc(path: "/api/rpc/sshHost/list", input: EmptyInput(),
			output: [RemoteHost].self)
	}

	public func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		try await rpc(path: "/api/rpc/sshHost/create", input: input,
			output: RemoteHostCreateOutput.self)
	}

	public func updateHost(_ input: RemoteHostUpdateInput) async throws {
		struct UpdateOut: Codable { let id: String }
		_ = try await rpc(path: "/api/rpc/sshHost/update", input: input,
			output: UpdateOut.self)
	}

	public func deleteHost(id: String) async throws {
		struct DeleteOut: Codable { let success: Bool }
		_ = try await rpc(path: "/api/rpc/sshHost/delete",
			input: RemoteHostIdInput(id: id),
			output: DeleteOut.self)
	}

	// MARK: - Private

	private func rpc<I: Encodable, O: Decodable>(path: String, input: I,
		output: O.Type) async throws -> O
	{
		var req = URLRequest(url: baseURL.appendingPathComponent(path))
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.httpBody = try encoder.encode(ORPCEnvelope(json: input))
		let (data, resp) = try await session.data(for: req)
		guard let http = resp as? HTTPURLResponse else {
			throw ServerSyncError.http(status: 0, body: "no http response")
		}
		// oRPC returns 4xx with a JSON envelope describing the error. Try
		// parseORPCResponse first; if it throws .orpc we surface that. If
		// status is non-2xx and the body isn't an oRPC envelope, surface
		// ServerSyncError.http with the raw body.
		do {
			return try parseORPCResponse(data, as: O.self)
		} catch let ServerSyncError.orpc(c, s, m) {
			throw ServerSyncError.orpc(code: c, status: s, message: m)
		} catch {
			if !(200..<300).contains(http.statusCode) {
				let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
				throw ServerSyncError.http(status: http.statusCode, body: bodyStr)
			}
			throw ServerSyncError.decode("\(error)")
		}
	}
}
