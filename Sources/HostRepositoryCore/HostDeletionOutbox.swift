import Foundation

public enum HostDeletionOutboxError: Error, Equatable, LocalizedError {
	case readFailed(String)
	case writeFailed(String)

	public var errorDescription: String? {
		switch self {
		case .readFailed(let detail):
			"Could not read the host deletion outbox: \(detail)"
		case .writeFailed(let detail):
			"Could not write the host deletion outbox: \(detail)"
		}
	}
}

private struct HostDeletionOutboxEnvelope: Codable {
	let schemaVersion: Int
	let pendingServerIDs: [String]
}

public struct HostDeletionOutbox {
	private static let schemaVersion = 1

	private let url: URL
	private var pendingServerIDs: Set<String> = []
	private var loadError: HostDeletionOutboxError?

	public init(hostsURL: URL) {
		url = hostsURL.deletingPathExtension()
			.appendingPathExtension("deletions.json")
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		do {
			let data = try Data(contentsOf: url)
			let envelope = try JSONDecoder().decode(
				HostDeletionOutboxEnvelope.self,
				from: data
			)
			guard envelope.schemaVersion == Self.schemaVersion else {
				loadError = .readFailed(
					"Unsupported host deletion outbox schema version \(envelope.schemaVersion)"
				)
				return
			}
			pendingServerIDs = Set(envelope.pendingServerIDs)
		} catch {
			loadError = .readFailed(error.localizedDescription)
		}
	}

	public func pendingIDs() throws -> [String] {
		if let loadError { throw loadError }
		return pendingServerIDs.sorted()
	}

	@discardableResult
	public mutating func insert(_ serverID: String) throws -> Bool {
		if let loadError { throw loadError }
		let inserted = pendingServerIDs.insert(serverID).inserted
		guard inserted else { return false }
		do {
			try persist()
		} catch {
			pendingServerIDs.remove(serverID)
			throw error
		}
		return true
	}

	public mutating func remove(_ serverID: String) throws {
		if let loadError { throw loadError }
		guard pendingServerIDs.contains(serverID) else { return }
		pendingServerIDs.remove(serverID)
		do {
			try persist()
		} catch {
			pendingServerIDs.insert(serverID)
			throw error
		}
	}

	private func persist() throws {
		let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
			".\(url.lastPathComponent).\(UUID().uuidString).tmp"
		)
		do {
			try FileManager.default.createDirectory(
				at: url.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			let envelope = HostDeletionOutboxEnvelope(
				schemaVersion: Self.schemaVersion,
				pendingServerIDs: pendingServerIDs.sorted()
			)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			try encoder.encode(envelope).write(to: temporaryURL)
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o600],
				ofItemAtPath: temporaryURL.path
			)
			if FileManager.default.fileExists(atPath: url.path) {
				_ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
			} else {
				try FileManager.default.moveItem(at: temporaryURL, to: url)
			}
		} catch {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw HostDeletionOutboxError.writeFailed(error.localizedDescription)
		}
	}
}
