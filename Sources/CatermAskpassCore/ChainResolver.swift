import Foundation

public struct AskpassChainEntry: Decodable, Equatable {
	public let hostId: String
	public let alias: String       // "caterm-h-<uuid>" — same as the Host block name in the generated ssh_config
	public let user: String
	public let hostname: String
	public let port: Int
	public let keyPath: String?
	public let credentialService: String?
	public let passwordAccount: String?
	public let passphraseAccount: String?
	public let useDataProtectionKeychain: Bool?

	public init(hostId: String, alias: String, user: String,
	            hostname: String, port: Int, keyPath: String?,
	            credentialService: String? = nil,
	            passwordAccount: String? = nil,
	            passphraseAccount: String? = nil,
	            useDataProtectionKeychain: Bool? = nil) {
		self.hostId = hostId
		self.alias = alias
		self.user = user
		self.hostname = hostname
		self.port = port
		self.keyPath = keyPath
		self.credentialService = credentialService
		self.passwordAccount = passwordAccount
		self.passphraseAccount = passphraseAccount
		self.useDataProtectionKeychain = useDataProtectionKeychain
	}
}

public enum AskpassLookup: Equatable {
	case password(hostId: String)
	case passphrase(hostId: String)
}

public enum AskpassResolution: Equatable {
	case found(AskpassLookup)
	case ambiguous              // multiple candidates, prompt has no port disambiguator
	case noMatch                // unknown prompt format or no chain entry
}

private let passwordRegex: NSRegularExpression = {
	// `<user>@<host>(:<port>)?'s password: `
	let pattern = #"^(?<user>[^@]+)@(?<host>[^:'\s]+)(?::(?<port>\d+))?'s password: $"#
	return try! NSRegularExpression(pattern: pattern)
}()

private let passphraseRegex: NSRegularExpression = {
	// `Enter passphrase for key '<absolute path>': `
	let pattern = #"^Enter passphrase for key '(?<path>/[^']+)': $"#
	return try! NSRegularExpression(pattern: pattern)
}()

public func resolveAskpassPrompt(
	_ prompt: String,
	chain: [AskpassChainEntry],
	consumedPasswordHostIDs: [String] = []
) -> AskpassResolution {
	if let m = matchPasswordPrompt(prompt) {
		return resolvePassword(
			matched: m,
			chain: chain,
			consumedPasswordHostIDs: consumedPasswordHostIDs
		)
	}
	if let m = matchPassphrasePrompt(prompt) {
		return resolvePassphrase(matched: m, chain: chain)
	}
	return .noMatch
}

private struct PasswordMatch {
	let user: String
	let host: String
	let port: Int?
}

private func matchPasswordPrompt(_ prompt: String) -> PasswordMatch? {
	let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
	guard let m = passwordRegex.firstMatch(in: prompt, range: range),
	      let userRange = Range(m.range(withName: "user"), in: prompt),
	      let hostRange = Range(m.range(withName: "host"), in: prompt)
	else { return nil }
	let portRange = Range(m.range(withName: "port"), in: prompt)
	let port = portRange.flatMap { Int(prompt[$0]) }
	return PasswordMatch(
		user: String(prompt[userRange]),
		host: String(prompt[hostRange]),
		port: port
	)
}

private func matchPassphrasePrompt(_ prompt: String) -> String? {
	let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
	guard let m = passphraseRegex.firstMatch(in: prompt, range: range),
	      let pathRange = Range(m.range(withName: "path"), in: prompt)
	else { return nil }
	return String(prompt[pathRange])
}

private func resolvePassword(
	matched: PasswordMatch,
	chain: [AskpassChainEntry],
	consumedPasswordHostIDs: [String]
) -> AskpassResolution {
	// Candidates: same user AND (alias OR hostname) match.
	let candidates = chain.filter { entry in
		entry.user == matched.user
			&& (entry.alias == matched.host || entry.hostname == matched.host)
	}
	if candidates.isEmpty { return .noMatch }
	if let port = matched.port {
		let portFiltered = candidates.filter { $0.port == port }
		guard portFiltered.count == 1, let chosen = portFiltered.first else {
			return portFiltered.isEmpty ? .noMatch : .ambiguous
		}
		return .found(.password(hostId: chosen.hostId))
	}
	// Portless prompt: must be exactly one candidate.
	if candidates.count == 1, let chosen = candidates.first {
		return .found(.password(hostId: chosen.hostId))
	}
	let remaining = candidates.filter { !consumedPasswordHostIDs.contains($0.hostId) }
	if let chosen = remaining.first {
		return .found(.password(hostId: chosen.hostId))
	}
	return .ambiguous
}

private func resolvePassphrase(matched path: String,
                               chain: [AskpassChainEntry]) -> AskpassResolution {
	let candidates = chain.filter { $0.keyPath == path }
	if candidates.count == 1, let chosen = candidates.first {
		return .found(.passphrase(hostId: chosen.hostId))
	}
	return .noMatch
}
