import Crypto
import Foundation

public enum KnownHostsSource: String, CaseIterable, Sendable {
	case caterm
	case user

	public var displayName: String {
		switch self {
		case .caterm: "Caterm"
		case .user: "OpenSSH"
		}
	}
}

public struct KnownHostRecord: Identifiable, Equatable, Sendable {
	public struct ID: Hashable, Sendable {
		public let source: KnownHostsSource
		public let rawLine: String
		public let occurrence: Int
	}

	public let id: ID
	public let source: KnownHostsSource
	public let hosts: [String]
	public let keyType: String?
	public let fingerprint: String?
	public let marker: String?
	public let comment: String?
	public let rawLine: String
	public let isValid: Bool

	public var isHashed: Bool {
		hosts.count == 1 && hosts[0].hasPrefix("|")
	}

	public var hostDisplay: String {
		if isHashed { return "Hashed host" }
		if hosts.isEmpty { return "Unrecognized entry" }
		return hosts.joined(separator: ", ")
	}

	public var markerDisplay: String {
		switch marker {
		case "@cert-authority": "Certificate authority"
		case "@revoked": "Revoked"
		case nil: isValid ? "Trusted host" : "Unrecognized"
		default: "Unrecognized"
		}
	}

	public var keyTypeDisplay: String {
		keyType ?? "Unknown"
	}

	public var sourceDisplay: String {
		source.displayName
	}

	public var searchText: String {
		[
			hostDisplay,
			hosts.joined(separator: " "),
			keyType ?? "",
			fingerprint ?? "",
			markerDisplay,
			source.displayName,
			comment ?? "",
		]
		.joined(separator: " ")
	}
}

public struct KnownHostsLoadIssue: Equatable, Sendable {
	public let source: KnownHostsSource
	public let message: String
}

public struct KnownHostsSnapshot: Equatable, Sendable {
	public let records: [KnownHostRecord]
	public let issues: [KnownHostsLoadIssue]

	public init(
		records: [KnownHostRecord],
		issues: [KnownHostsLoadIssue]
	) {
		self.records = records
		self.issues = issues
	}
}

public enum KnownHostsStoreError: Error, Equatable, Sendable {
	case invalidUTF8(path: String)
	case recordNoLongerExists
	case unreadableFile(path: String)
}

extension KnownHostsStoreError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidUTF8(let path):
			"The known-hosts file is not valid UTF-8: \(path)"
		case .recordNoLongerExists:
			"The known-host entry changed or was removed. Refresh and try again."
		case .unreadableFile(let path):
			"The known-hosts file could not be read: \(path)"
		}
	}
}

public struct KnownHostsRepository: Sendable {
	public let catermURL: URL
	public let userURL: URL

	public init(catermURL: URL, userURL: URL) {
		self.catermURL = catermURL
		self.userURL = userURL
	}

	public func load() -> KnownHostsSnapshot {
		var records: [KnownHostRecord] = []
		var issues: [KnownHostsLoadIssue] = []
		for source in KnownHostsSource.allCases {
			do {
				records += try parseRecords(in: url(for: source), source: source)
			} catch {
				issues.append(
					KnownHostsLoadIssue(
						source: source,
						message: error.localizedDescription
					)
				)
			}
		}
		return KnownHostsSnapshot(records: records, issues: issues)
	}

	public func delete(_ record: KnownHostRecord) throws {
		let destination = url(for: record.source)
		let text = try readText(at: destination)
		var lines = text.components(separatedBy: "\n")
		var occurrence = 0
		var matchedIndex: Int?
		for (index, line) in lines.enumerated() where line == record.rawLine {
			if occurrence == record.id.occurrence {
				matchedIndex = index
				break
			}
			occurrence += 1
		}
		guard let matchedIndex else {
			throw KnownHostsStoreError.recordNoLongerExists
		}
		lines.remove(at: matchedIndex)
		try write(lines.joined(separator: "\n"), to: destination)
	}

	@discardableResult
	public func importEntries(from sourceURL: URL) throws -> Int {
		let importedRecords = try parseRecords(in: sourceURL, source: .caterm)
			.filter(\.isValid)
		let existingText = try readTextIfPresent(at: catermURL) ?? ""
		let existingLines = Set(
			existingText.components(separatedBy: "\n").map {
				$0.trimmingCharacters(in: .whitespacesAndNewlines)
			}
		)
		var seen = existingLines
		let newLines = importedRecords.compactMap { record -> String? in
			let normalized = record.rawLine.trimmingCharacters(
				in: .whitespacesAndNewlines
			)
			guard seen.insert(normalized).inserted else { return nil }
			return normalized
		}
		guard !newLines.isEmpty else { return 0 }

		var updatedText = existingText
		if !updatedText.isEmpty && !updatedText.hasSuffix("\n") {
			updatedText += "\n"
		}
		updatedText += newLines.joined(separator: "\n") + "\n"
		try write(updatedText, to: catermURL)
		return newLines.count
	}

	private func url(for source: KnownHostsSource) -> URL {
		switch source {
		case .caterm: catermURL
		case .user: userURL
		}
	}

	private func parseRecords(
		in url: URL,
		source: KnownHostsSource
	) throws -> [KnownHostRecord] {
		guard let text = try readTextIfPresent(at: url) else { return [] }
		var occurrences: [String: Int] = [:]
		return text.components(separatedBy: "\n").compactMap { rawLine in
			let occurrence = occurrences[rawLine, default: 0]
			occurrences[rawLine] = occurrence + 1
			return Self.parse(
				rawLine: rawLine,
				source: source,
				occurrence: occurrence
			)
		}
	}

	private static func parse(
		rawLine: String,
		source: KnownHostsSource,
		occurrence: Int
	) -> KnownHostRecord? {
		let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
		let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
		let marker = fields.first?.hasPrefix("@") == true ? fields.first : nil
		let hostIndex = marker == nil ? 0 : 1
		let keyTypeIndex = hostIndex + 1
		let keyIndex = hostIndex + 2
		let markerIsValid = marker == nil
			|| marker == "@cert-authority"
			|| marker == "@revoked"
		let hasRequiredFields = fields.indices.contains(keyIndex)
		let keyData = hasRequiredFields
			? Data(base64Encoded: fields[keyIndex])
			: nil
		let isValid = markerIsValid && hasRequiredFields && keyData != nil
		let hosts = fields.indices.contains(hostIndex)
			? fields[hostIndex].split(separator: ",").map(String.init)
			: []
		let commentStart = keyIndex + 1
		let comment = fields.indices.contains(commentStart)
			? fields[commentStart...].joined(separator: " ")
			: nil
		let fingerprint = keyData.map { data in
			let digest = SHA256.hash(data: data)
			let encoded = Data(digest).base64EncodedString()
				.trimmingCharacters(in: CharacterSet(charactersIn: "="))
			return "SHA256:\(encoded)"
		}

		return KnownHostRecord(
			id: .init(
				source: source,
				rawLine: rawLine,
				occurrence: occurrence
			),
			source: source,
			hosts: hosts,
			keyType: fields.indices.contains(keyTypeIndex) ? fields[keyTypeIndex] : nil,
			fingerprint: fingerprint,
			marker: marker,
			comment: comment,
			rawLine: rawLine,
			isValid: isValid
		)
	}

	private func readText(at url: URL) throws -> String {
		guard let text = try readTextIfPresent(at: url) else {
			throw KnownHostsStoreError.recordNoLongerExists
		}
		return text
	}

	private func readTextIfPresent(at url: URL) throws -> String? {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(
			atPath: url.path,
			isDirectory: &isDirectory
		) else { return nil }
		guard !isDirectory.boolValue,
		      let data = try? Data(contentsOf: url) else {
			throw KnownHostsStoreError.unreadableFile(path: url.path)
		}
		guard let text = String(data: data, encoding: .utf8) else {
			throw KnownHostsStoreError.invalidUTF8(path: url.path)
		}
		return text
	}

	private func write(_ text: String, to url: URL) throws {
		let destination = url.resolvingSymlinksInPath()
		let fileManager = FileManager.default
		let existingAttributes = try? fileManager.attributesOfItem(
			atPath: destination.path
		)
		try fileManager.createDirectory(
			at: destination.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data(text.utf8).write(to: destination, options: .atomic)
		let permissions = existingAttributes?[.posixPermissions] ?? NSNumber(value: 0o600)
		try fileManager.setAttributes(
			[.posixPermissions: permissions],
			ofItemAtPath: destination.path
		)
	}
}
