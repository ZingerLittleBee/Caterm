import Foundation
import SSHCommandBuilder

public enum MobileHostFormMode: Equatable {
	case add
	case edit(SSHHost)
}

public struct MobileHostDraftPayload: Equatable {
	public let host: SSHHost
	public let secret: String?
}

public struct MobileHostDraft: Equatable {
	public enum ValidationError: Error, Equatable {
		case missingHostname
		case missingUsername
		case invalidPort
		case missingKeyPath
	}

	public enum Credential: Equatable {
		case password(secret: String)
		case keyFile(path: String, hasPassphrase: Bool, secret: String)
		case agent
	}

	public var label: String
	public var hostname: String
	public var port: String
	public var username: String
	public var credential: Credential
	public var jumpHostId: UUID?
	public var forwards: [PortForward]

	public init(
		label: String = "",
		hostname: String = "",
		port: String = "22",
		username: String = "",
		credential: Credential = .password(secret: ""),
		jumpHostId: UUID? = nil,
		forwards: [PortForward] = []
	) {
		self.label = label
		self.hostname = hostname
		self.port = port
		self.username = username
		self.credential = credential
		self.jumpHostId = jumpHostId
		self.forwards = forwards
	}

	public init(host: SSHHost) {
		let derived = "\(host.username)@\(host.hostname)"
		self.label = host.name == derived ? "" : host.name
		self.hostname = host.hostname
		self.port = String(host.port)
		self.username = host.username
		switch host.credential {
		case .password:
			self.credential = .password(secret: "")
		case let .keyFile(path, hasPassphrase):
			self.credential = .keyFile(path: path, hasPassphrase: hasPassphrase, secret: "")
		case .agent:
			self.credential = .agent
		}
		self.jumpHostId = host.jumpHostId
		self.forwards = host.forwards
	}

	public func build(mode: MobileHostFormMode, allHosts: [SSHHost]) throws -> MobileHostDraftPayload {
		let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedHostname.isEmpty else { throw ValidationError.missingHostname }
		let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedUsername.isEmpty else { throw ValidationError.missingUsername }
		guard let parsedPort = Int(port), (1...65_535).contains(parsedPort) else {
			throw ValidationError.invalidPort
		}

		let credentialSource: CredentialSource
		let secret: String?
		switch credential {
		case .password(let value):
			credentialSource = .password
			secret = value.isEmpty ? nil : value
		case let .keyFile(path, hasPassphrase, value):
			let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmedPath.isEmpty else { throw ValidationError.missingKeyPath }
			credentialSource = .keyFile(keyPath: trimmedPath, hasPassphrase: hasPassphrase)
			secret = hasPassphrase && !value.isEmpty ? value : nil
		case .agent:
			credentialSource = .agent
			secret = nil
		}

		var host: SSHHost
		switch mode {
		case .add:
			host = SSHHost(
				name: resolvedName(username: trimmedUsername, hostname: trimmedHostname),
				hostname: trimmedHostname,
				port: parsedPort,
				username: trimmedUsername,
				credential: credentialSource
			)
		case .edit(let existing):
			host = existing
			host.name = resolvedName(username: trimmedUsername, hostname: trimmedHostname)
			host.hostname = trimmedHostname
			host.port = parsedPort
			host.username = trimmedUsername
			host.credential = credentialSource
		}

		host.jumpHostId = jumpHostId
		host.jumpHostServerId = jumpHostId.flatMap { id in
			allHosts.first(where: { $0.id == id })?.serverId
		}
		host.forwards = forwards
		return MobileHostDraftPayload(host: host, secret: secret)
	}

	private func resolvedName(username: String, hostname: String) -> String {
		let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmedLabel.isEmpty ? "\(username)@\(hostname)" : trimmedLabel
	}
}
