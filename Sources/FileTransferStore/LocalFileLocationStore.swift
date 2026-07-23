#if os(macOS)
import Foundation

public struct LocalFileLocation:
	Codable, Equatable, Hashable, Identifiable, Sendable {
	public let id: UUID
	public let displayName: String
	public let bookmarkData: Data

	public init(
		id: UUID = UUID(),
		displayName: String,
		bookmarkData: Data
	) {
		self.id = id
		self.displayName = displayName
		self.bookmarkData = bookmarkData
	}
}

public enum LocalFileLocationError: Error, Equatable, Sendable {
	case missing(UUID)
	case unavailable(id: UUID, displayName: String)
	case accessDenied(String)
}

extension LocalFileLocationError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .missing:
			"The saved local location no longer exists."
		case .unavailable(_, let displayName):
			"\(displayName) is unavailable. Choose the folder again to restore access."
		case .accessDenied(let path):
			"Caterm cannot access \(path). Choose the folder again to restore access."
		}
	}
}

struct SecurityScopedBookmarkResolution: Sendable {
	let url: URL
	let isStale: Bool
}

protocol SecurityScopedBookmarkCoding: Sendable {
	func createBookmark(for url: URL) throws -> Data
	func resolveBookmark(
		_ data: Data
	) throws -> SecurityScopedBookmarkResolution
	func startAccessing(_ url: URL) -> Bool
	func stopAccessing(_ url: URL)
	func isReachable(_ url: URL) -> Bool
}

struct FoundationSecurityScopedBookmarkCodec:
	SecurityScopedBookmarkCoding, Sendable {
	func createBookmark(for url: URL) throws -> Data {
		try url.bookmarkData(
			options: [.withSecurityScope],
			includingResourceValuesForKeys: nil,
			relativeTo: nil
		)
	}

	func resolveBookmark(
		_ data: Data
	) throws -> SecurityScopedBookmarkResolution {
		var isStale = false
		let url = try URL(
			resolvingBookmarkData: data,
			options: [.withSecurityScope],
			relativeTo: nil,
			bookmarkDataIsStale: &isStale
		)
		return SecurityScopedBookmarkResolution(
			url: url,
			isStale: isStale
		)
	}

	func startAccessing(_ url: URL) -> Bool {
		url.startAccessingSecurityScopedResource()
	}

	func stopAccessing(_ url: URL) {
		url.stopAccessingSecurityScopedResource()
	}

	func isReachable(_ url: URL) -> Bool {
		(try? url.checkResourceIsReachable()) == true
	}
}

protocol LocalFileResourceAccessing: Sendable {
	var url: URL { get }
	func startAccessing() throws
	func stopAccessing()
}

private final class SecurityScopedURLResourceAccess:
	LocalFileResourceAccessing, @unchecked Sendable {
	let url: URL

	private let codec: any SecurityScopedBookmarkCoding
	private let lock = NSLock()
	private var accessCount = 0
	private var ownsSecurityScope = false

	init(
		url: URL,
		codec: any SecurityScopedBookmarkCoding
	) {
		self.url = url
		self.codec = codec
	}

	func startAccessing() throws {
		try lock.withLock {
			if accessCount == 0 {
				let scoped = codec.startAccessing(url)
				guard scoped || codec.isReachable(url) else {
					throw LocalFileLocationError.accessDenied(url.path)
				}
				ownsSecurityScope = scoped
			}
			accessCount += 1
		}
	}

	func stopAccessing() {
		lock.withLock {
			guard accessCount > 0 else { return }
			accessCount -= 1
			guard accessCount == 0, ownsSecurityScope else { return }
			ownsSecurityScope = false
			codec.stopAccessing(url)
		}
	}

	deinit {
		let shouldStop = lock.withLock {
			let result = ownsSecurityScope
			accessCount = 0
			ownsSecurityScope = false
			return result
		}
		if shouldStop {
			codec.stopAccessing(url)
		}
	}
}

public final class LocalFileAccessGrant: @unchecked Sendable {
	public let url: URL
	private let resourceAccess: any LocalFileResourceAccessing

	init(
		url: URL,
		resourceAccess: any LocalFileResourceAccessing
	) {
		self.url = url
		self.resourceAccess = resourceAccess
	}

	public func withAccess<Value: Sendable>(
		_ operation: @escaping @Sendable (URL) async throws -> Value
	) async throws -> Value {
		try resourceAccess.startAccessing()
		defer { resourceAccess.stopAccessing() }
		return try await operation(url)
	}
}

public actor LocalFileLocationStore {
	public static var defaultFileURL: URL {
		let root = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first ?? FileManager.default.temporaryDirectory
		return root
			.appendingPathComponent("Caterm", isDirectory: true)
			.appendingPathComponent(
				"LocalFileLocations.json",
				isDirectory: false
			)
	}

	public private(set) var locations: [LocalFileLocation]

	private let fileURL: URL
	private let bookmarkCodec: any SecurityScopedBookmarkCoding

	public init(
		fileURL: URL = LocalFileLocationStore.defaultFileURL
	) {
		self.init(
			fileURL: fileURL,
			bookmarkCodec: FoundationSecurityScopedBookmarkCodec()
		)
	}

	init(
		fileURL: URL,
		bookmarkCodec: any SecurityScopedBookmarkCoding
	) {
		self.fileURL = fileURL
		self.bookmarkCodec = bookmarkCodec
		locations = Self.load(fileURL: fileURL)
	}

	public func location(_ id: UUID) -> LocalFileLocation? {
		locations.first { $0.id == id }
	}

	@discardableResult
	public func add(
		url: URL,
		displayName: String? = nil
	) throws -> LocalFileLocation {
		let location = LocalFileLocation(
			displayName: displayName ?? url.lastPathComponent,
			bookmarkData: try bookmarkCodec.createBookmark(for: url)
		)
		locations.append(location)
		do {
			try persist()
		} catch {
			locations.removeAll { $0.id == location.id }
			throw error
		}
		return location
	}

	@discardableResult
	public func reauthorize(
		_ id: UUID,
		with url: URL
	) throws -> LocalFileLocation {
		guard let index = locations.firstIndex(where: { $0.id == id }) else {
			throw LocalFileLocationError.missing(id)
		}
		let updated = LocalFileLocation(
			id: id,
			displayName: locations[index].displayName,
			bookmarkData: try bookmarkCodec.createBookmark(for: url)
		)
		let previous = locations[index]
		locations[index] = updated
		do {
			try persist()
		} catch {
			locations[index] = previous
			throw error
		}
		return updated
	}

	public func remove(_ id: UUID) throws {
		let previous = locations
		locations.removeAll { $0.id == id }
		do {
			try persist()
		} catch {
			locations = previous
			throw error
		}
	}

	public func access(_ id: UUID) throws -> LocalFileAccessGrant {
		guard let index = locations.firstIndex(where: { $0.id == id }) else {
			throw LocalFileLocationError.missing(id)
		}
		var location = locations[index]
		let resolution = try bookmarkCodec.resolveBookmark(
			location.bookmarkData
		)
		if resolution.isStale {
			let previous = location
			location = LocalFileLocation(
				id: location.id,
				displayName: location.displayName,
				bookmarkData: try bookmarkCodec.createBookmark(
					for: resolution.url
				)
			)
			locations[index] = location
			do {
				try persist()
			} catch {
				locations[index] = previous
				throw error
			}
		}
		guard bookmarkCodec.isReachable(resolution.url) else {
			throw LocalFileLocationError.unavailable(
				id: location.id,
				displayName: location.displayName
			)
		}
		return LocalFileAccessGrant(
			url: resolution.url,
			resourceAccess: SecurityScopedURLResourceAccess(
				url: resolution.url,
				codec: bookmarkCodec
			)
		)
	}

	private static func load(fileURL: URL) -> [LocalFileLocation] {
		guard let data = try? Data(contentsOf: fileURL) else { return [] }
		return (try? JSONDecoder().decode(
			[LocalFileLocation].self,
			from: data
		)) ?? []
	}

	private func persist() throws {
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let data = try JSONEncoder().encode(locations)
		try data.write(to: fileURL, options: [.atomic])
	}
}
#endif
