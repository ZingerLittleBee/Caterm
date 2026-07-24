import Darwin
import Foundation

public final class MobileKnownHostsStore: @unchecked Sendable {
	public enum Verdict: Equatable {
		case trusted
		case unknown
		case mismatch
	}

	private let fileURL: URL
	private let persist: @Sendable (Data, URL) throws -> Void
	private let lock = NSLock()
	private var map: [String: String]

	public init(fileURL: URL) {
		self.fileURL = fileURL
		self.persist = { data, destination in
			try data.write(to: destination, options: .atomic)
		}
		self.map = [:]
	}

	init(
		fileURL: URL,
		persist: @escaping @Sendable (Data, URL) throws -> Void
	) {
		self.fileURL = fileURL
		self.persist = persist
		self.map = [:]
	}

	public func evaluate(endpoint: String, fingerprint: String) throws -> Verdict {
		lock.lock()
		defer { lock.unlock() }
		map = try Self.load(from: fileURL)
		guard let known = map[endpoint] else { return .unknown }
		return known == fingerprint ? .trusted : .mismatch
	}

	public func trust(endpoint: String, fingerprint: String) throws {
		lock.lock()
		defer { lock.unlock() }
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try withExclusiveFileLock {
			let persisted = try Self.load(from: fileURL)
			if let known = persisted[endpoint], known != fingerprint {
				throw MobileKnownHostsError.concurrentKeyChange(endpoint: endpoint)
			}
			var candidate = persisted
			candidate[endpoint] = fingerprint
			let data = try JSONEncoder().encode(candidate)
			try persist(data, fileURL)
			map = candidate
		}
	}

	private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
		let lockPath = fileURL.path + ".lock"
		let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
		guard descriptor >= 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		defer { close(descriptor) }
		guard flock(descriptor, LOCK_EX) == 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		defer { flock(descriptor, LOCK_UN) }
		return try operation()
	}

	private static func load(from fileURL: URL) throws -> [String: String] {
		let data: Data
		do {
			data = try Data(contentsOf: fileURL)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return [:]
		} catch {
			throw MobileKnownHostsError.unreadable(path: fileURL.path)
		}
		do {
			return try JSONDecoder().decode([String: String].self, from: data)
		} catch {
			throw MobileKnownHostsError.invalidData(path: fileURL.path)
		}
	}
}

public enum MobileKnownHostsError: Error, Equatable, Sendable {
	case concurrentKeyChange(endpoint: String)
	case unreadable(path: String)
	case invalidData(path: String)
}
