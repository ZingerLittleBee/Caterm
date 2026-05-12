import Foundation

public struct PortForward: Codable, Hashable, Identifiable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		case local
		case remote
		case dynamic
	}

	public enum BindFailureReason: String, Codable, Error, Sendable {
		case alreadyInUse
		case permissionDenied
		case unknown
	}

	public enum ValidationError: Error, Equatable, Sendable {
		case bindPortOutOfRange(Int)
		case remotePortOutOfRange(Int)
		case missingRemoteForLocalOrRemote
		case unexpectedRemoteForDynamic
		case duplicateBinding(kind: Kind, bindAddress: String, bindPort: Int)
	}

	private static let validPortRange: ClosedRange<Int> = 1...65535

	public let id: UUID
	public var kind: Kind
	public var bindAddress: String?
	public var bindPort: Int
	public var remoteHost: String?
	public var remotePort: Int?
	public var required: Bool
	public var label: String?

	public init(
		id: UUID = UUID(),
		kind: Kind,
		bindAddress: String? = nil,
		bindPort: Int,
		remoteHost: String? = nil,
		remotePort: Int? = nil,
		required: Bool = true,
		label: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.bindAddress = bindAddress
		self.bindPort = bindPort
		self.remoteHost = remoteHost
		self.remotePort = remotePort
		self.required = required
		self.label = label
	}

	/// Validates one forward in isolation. Cross-forward uniqueness lives in
	/// `validateCollection(_:)`.
	public func validate() throws {
		guard Self.validPortRange.contains(bindPort) else {
			throw ValidationError.bindPortOutOfRange(bindPort)
		}
		if let p = remotePort, !Self.validPortRange.contains(p) {
			throw ValidationError.remotePortOutOfRange(p)
		}
		switch kind {
		case .local, .remote:
			guard let host = remoteHost, !host.isEmpty, remotePort != nil else {
				throw ValidationError.missingRemoteForLocalOrRemote
			}
		case .dynamic:
			guard remoteHost == nil, remotePort == nil else {
				throw ValidationError.unexpectedRemoteForDynamic
			}
		}
	}

	/// Validates a list and rejects same (kind, bindAddress, bindPort) tuples.
	public static func validateCollection(_ forwards: [PortForward]) throws {
		var seen: Set<String> = []
		for f in forwards {
			try f.validate()
			let key = "\(f.kind.rawValue)|\(f.bindAddress ?? "localhost")|\(f.bindPort)"
			if !seen.insert(key).inserted {
				throw ValidationError.duplicateBinding(
					kind: f.kind,
					bindAddress: f.bindAddress ?? "localhost",
					bindPort: f.bindPort
				)
			}
		}
	}

	/// Serializes this forward to one `ssh_config` line. Caller is responsible
	/// for prepending any indentation. Values that contain whitespace or
	/// control characters are encoded via `SSHConfigQuote.encode`.
	public func sshConfigLine() throws -> String {
		let bindPart: String
		if let addr = bindAddress, !addr.isEmpty {
			bindPart = "\(addr):\(bindPort)"
		} else {
			bindPart = String(bindPort)
		}
		switch kind {
		case .local:
			let target = "\(remoteHost ?? ""):\(remotePort ?? 0)"
			return "LocalForward \(try SSHConfigQuote.encode(bindPart)) \(try SSHConfigQuote.encode(target))"
		case .remote:
			let target = "\(remoteHost ?? ""):\(remotePort ?? 0)"
			return "RemoteForward \(try SSHConfigQuote.encode(bindPart)) \(try SSHConfigQuote.encode(target))"
		case .dynamic:
			return "DynamicForward \(try SSHConfigQuote.encode(bindPart))"
		}
	}
}
