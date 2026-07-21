import Foundation
import SSHCommandBuilder

struct QuickConnectDestination: Equatable {
	let username: String
	let hostname: String
	let port: Int

	var displayAddress: String {
		let displayedHostname = hostname.contains(":") ? "[\(hostname)]" : hostname
		return "\(username)@\(displayedHostname):\(port)"
	}

	func makeHost() -> SSHHost {
		SSHHost(
			name: hostname,
			hostname: hostname,
			port: port,
			username: username,
			credential: .agent
		)
	}
}

enum QuickConnectParser {
	static func parse(_ input: String) -> QuickConnectDestination? {
		var tokens = input.split(whereSeparator: \Character.isWhitespace).map(String.init)
		if tokens.first == "ssh" {
			tokens.removeFirst()
		}
		let destination: String
		var port: Int
		let hasPortOption: Bool
		if tokens.count == 1 {
			destination = tokens[0]
			port = 22
			hasPortOption = false
		} else if tokens.count == 3 {
			if tokens[1] == "-p", let parsedPort = Int(tokens[2]) {
				destination = tokens[0]
				port = parsedPort
				hasPortOption = true
			} else if tokens[0] == "-p", let parsedPort = Int(tokens[1]) {
				destination = tokens[2]
				port = parsedPort
				hasPortOption = true
			} else {
				return nil
			}
		} else {
			return nil
		}
		guard let separator = destination.firstIndex(of: "@") else { return nil }
		let username = String(destination[..<separator])
		var hostname = String(destination[destination.index(after: separator)...])
		if hostname.hasPrefix("[") {
			guard let closingBracket = hostname.firstIndex(of: "]") else { return nil }
			let address = hostname.index(after: hostname.startIndex)..<closingBracket
			let suffix = hostname[hostname.index(after: closingBracket)...]
			if suffix.isEmpty {
				hostname = String(hostname[address])
			} else {
				guard !hasPortOption, suffix.first == ":",
				      let compactPort = Int(suffix.dropFirst()) else { return nil }
				hostname = String(hostname[address])
				port = compactPort
			}
		} else if hostname.filter({ $0 == ":" }).count == 1 {
			guard let portSeparator = hostname.lastIndex(of: ":"),
			      let compactPort = Int(hostname[hostname.index(after: portSeparator)...])
			else { return nil }
			guard !hasPortOption else { return nil }
			hostname = String(hostname[..<portSeparator])
			port = compactPort
		}
		guard !username.isEmpty, !hostname.isEmpty, !hostname.contains("@"),
		      (1...65535).contains(port) else { return nil }
		return QuickConnectDestination(
			username: username,
			hostname: hostname,
			port: port
		)
	}
}
