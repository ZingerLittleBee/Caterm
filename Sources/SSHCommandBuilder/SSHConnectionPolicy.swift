import Foundation
import SSHCredentialContract

public enum SSHAuthenticationMode: Sendable, Equatable {
	case configuredCredential
	case interactive
}

public struct SSHRuntimeIdentityOptions: Sendable, Equatable {
	public let certificatePath: String?
	public let identityAgentPath: String?

	public init(
		certificatePath: String? = nil,
		identityAgentPath: String? = nil
	) {
		self.certificatePath = certificatePath
		self.identityAgentPath = identityAgentPath
	}
}

package enum SSHOptionKind: Equatable {
	case option(keyword: String)
	case identityFile(path: String)
}

/// A semantic OpenSSH option. Renderers choose argv or ssh_config syntax.
package struct SSHOption: Equatable {
	package let kind: SSHOptionKind
	package let arguments: [String]

	package static func option(_ keyword: String, _ arguments: String...) -> SSHOption {
		SSHOption(kind: .option(keyword: keyword), arguments: arguments)
	}

	package static func identityFile(_ path: String) -> SSHOption {
		SSHOption(kind: .identityFile(path: path), arguments: [])
	}

	package func invocationArguments() throws -> [String] {
		switch kind {
		case let .option(keyword):
			let encoded = try arguments.map(SSHConfigQuote.encode).joined(separator: " ")
			return ["-o", "\(keyword)=\(encoded)"]
		case let .identityFile(path):
			return ["-i", path]
		}
	}

	package func configLine() throws -> String {
		switch kind {
		case let .option(keyword):
			let encoded = try arguments.map(SSHConfigQuote.encode).joined(separator: " ")
			return "\(keyword) \(encoded)"
		case let .identityFile(path):
			return "IdentityFile \(try SSHConfigQuote.encode(path))"
		}
	}
}

package enum SSHHopRole: Equatable {
	case jump
	case target
}

package struct SSHHostPlan: Equatable {
	package let options: [SSHOption]
	package let credentialKind: SSHCredentialKind?

	package var needsAskpass: Bool { credentialKind != nil }
}

/// Owns the OpenSSH option policy. Callers only render its semantic plan.
package enum SSHConnectionPolicy {
	package static let controlPersist = "10m"

	package static func interactiveHostPlan(
		for host: SSHHost,
		role: SSHHopRole,
		knownHostsFiles: [String],
		authenticationMode: SSHAuthenticationMode = .configuredCredential,
		runtimeIdentity: SSHRuntimeIdentityOptions? = nil,
		controlPath: String? = nil
	) -> SSHHostPlan {
		let resolvedControlPath = controlPath
			?? "~/Library/Caches/Caterm/cm/\(host.id.uuidString).sock"
		var options: [SSHOption] = [
			.option("StrictHostKeyChecking", "accept-new"),
			.option("UserKnownHostsFile", knownHostsFiles),
			.option("ControlMaster", "auto"),
			.option("ControlPersist", controlPersist),
			.option("ControlPath", resolvedControlPath),
		]

		let credentialKind: SSHCredentialKind?
		if authenticationMode == .interactive {
			credentialKind = nil
		} else {
			switch host.credential {
			case .password:
				options += [
					.option("PreferredAuthentications", "password,keyboard-interactive"),
					.option("PubkeyAuthentication", "no"),
					.option("NumberOfPasswordPrompts", "1"),
				]
				credentialKind = .password

			case let .keyFile(keyPath, hasPassphrase):
				options += [
					.option("IdentitiesOnly", "yes"),
					.option("PreferredAuthentications", "publickey"),
					.option("PasswordAuthentication", "no"),
					.option("KbdInteractiveAuthentication", "no"),
					.identityFile(keyPath),
				]
				if let certificatePath = runtimeIdentity?.certificatePath {
					options.append(
						.option("CertificateFile", certificatePath)
					)
				}
				credentialKind = hasPassphrase ? .keyPassphrase : nil

			case .agent:
				options += [
					.option("BatchMode", "yes"),
					.option("IdentitiesOnly", "yes"),
				]
				if let identityAgentPath = runtimeIdentity?.identityAgentPath {
					options.append(
						.option("IdentityAgent", identityAgentPath)
					)
				}
				credentialKind = nil
			}
		}

		if role == .target, !host.forwards.isEmpty {
			options += host.forwards.map(\.sshOption)
			if host.forwards.allSatisfy(\.required) {
				options.append(.option("ExitOnForwardFailure", "yes"))
			}
		}

		return SSHHostPlan(options: options, credentialKind: credentialKind)
	}

	package static func existingControlSocketPlan(
		controlPath: String,
		strictHostKeyChecking: String,
		knownHostsFiles: [String]
	) -> [SSHOption] {
		[
			.option("ControlMaster", "no"),
			.option("BatchMode", "yes"),
			.option("PreferredAuthentications", "none"),
			.option("ProxyCommand", "none"),
			.option("ControlPath", controlPath),
			.option("ControlPersist", controlPersist),
			.option("StrictHostKeyChecking", strictHostKeyChecking),
			.option("UserKnownHostsFile", knownHostsFiles),
		]
	}
}

private extension SSHOption {
	static func option(_ keyword: String, _ arguments: [String]) -> SSHOption {
		SSHOption(kind: .option(keyword: keyword), arguments: arguments)
	}
}
