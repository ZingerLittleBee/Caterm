import Foundation

public final class MobileKnownHostsStore {
	public enum Verdict: Equatable {
		case trusted
		case unknown
		case mismatch
	}

	private let fileURL: URL
	private var map: [String: String]

	public init(fileURL: URL) {
		self.fileURL = fileURL
		if let data = try? Data(contentsOf: fileURL),
		   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
			self.map = decoded
		} else {
			self.map = [:]
		}
	}

	public func evaluate(endpoint: String, fingerprint: String) -> Verdict {
		guard let known = map[endpoint] else { return .unknown }
		return known == fingerprint ? .trusted : .mismatch
	}

	public func trust(endpoint: String, fingerprint: String) throws {
		map[endpoint] = fingerprint
		let data = try JSONEncoder().encode(map)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true)
		try data.write(to: fileURL)
	}
}
