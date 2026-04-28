import Foundation

/// `{"json": T}` wire envelope used by oRPC's RPCLink format.
public struct ORPCEnvelope<T> {
    public let json: T
    public init(json: T) { self.json = json }
}

extension ORPCEnvelope: Encodable where T: Encodable {}
extension ORPCEnvelope: Decodable where T: Decodable {}

/// Empty input marker. Encodes as `{}` — the body shape oRPC expects for
/// void-input procedures like `sshHost.list`.
public struct EmptyInput: Codable, Equatable {
    public init() {}
}

/// Decodes `{"json": ...}` from server. If the inner shape matches an oRPC
/// error envelope (`{defined: false, code, status, message}`), throws
/// `ServerSyncError.orpc` instead of returning it.
public func parseORPCResponse<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601

    // First try to decode as an error envelope.
    if let errEnv = try? dec.decode(DecodableEnvelope<ORPCErrorPayload>.self, from: data),
       errEnv.json.defined == false {
        throw ServerSyncError.orpc(code: errEnv.json.code,
                                   status: errEnv.json.status,
                                   message: errEnv.json.message)
    }

    let env = try dec.decode(DecodableEnvelope<T>.self, from: data)
    return env.json
}

/// Internal decode-only envelope used by parseORPCResponse.
private struct DecodableEnvelope<T: Decodable>: Decodable {
    let json: T
}

private struct ORPCErrorPayload: Codable {
    let defined: Bool
    let code: String
    let status: Int
    let message: String
}
