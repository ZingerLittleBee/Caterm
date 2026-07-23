#if os(macOS)
import Foundation
import Security

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
	case invalidRelativePath(String)
}

public enum LocalFileLocationLoadError: Error, Equatable, Sendable {
	case unreadable(String)
	case invalidData(String)
}

extension LocalFileLocationLoadError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .unreadable(let message):
			"Saved local locations could not be read: \(message)"
		case .invalidData(let message):
			"Saved local locations are invalid: \(message)"
		}
	}
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
		case .invalidRelativePath(let path):
			"The local path escapes its authorized folder: \(path)"
		}
	}
}

struct SecurityScopedBookmarkResolution: Sendable {
	let url: URL
	let isStale: Bool
}

protocol SecurityScopedBookmarkCoding: Sendable {
	var requiresSecurityScope: Bool { get }
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
	var requiresSecurityScope: Bool {
		guard let task = SecTaskCreateFromSelf(nil),
			let value = SecTaskCopyValueForEntitlement(
				task,
				"com.apple.security.app-sandbox" as CFString,
				nil
			) else {
			return false
		}
		return (value as? Bool) == true
	}

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
				let accessibleWithoutScope =
					!codec.requiresSecurityScope && codec.isReachable(url)
				guard scoped || accessibleWithoutScope else {
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
	private let authorizedRootURL: URL

	init(
		url: URL,
		resourceAccess: any LocalFileResourceAccessing,
		authorizedRootURL: URL? = nil
	) {
		self.url = url
		self.resourceAccess = resourceAccess
		self.authorizedRootURL = authorizedRootURL ?? resourceAccess.url
	}

	public func withAccess<Value: Sendable>(
		_ operation: @escaping @Sendable (URL) async throws -> Value
	) async throws -> Value {
		try resourceAccess.startAccessing()
		defer { resourceAccess.stopAccessing() }
		let safeURL = try await Task.detached {
			try Self.validatedURL(
				self.url,
				inside: self.authorizedRootURL
			)
		}.value
		return try await operation(
			safeURL
		)
	}

	public func descendant(
		relativePath: String
	) throws -> LocalFileAccessGrant {
		let components = relativePath.split(
			separator: "/",
			omittingEmptySubsequences: true
		)
		guard components.allSatisfy({
			$0 != "." && $0 != ".."
		}) else {
			throw LocalFileLocationError.invalidRelativePath(relativePath)
		}
		var descendant = url
		for component in components {
			descendant.appendPathComponent(String(component))
		}
		return LocalFileAccessGrant(
			url: descendant,
			resourceAccess: resourceAccess,
			authorizedRootURL: authorizedRootURL
		)
	}

	private static func validatedURL(
		_ candidate: URL,
		inside root: URL
	) throws -> URL {
		let lexicalRoot = root.standardizedFileURL
		let lexicalCandidate = candidate.standardizedFileURL
		let lexicalPrefix = lexicalRoot.path.hasSuffix("/")
			? lexicalRoot.path
			: lexicalRoot.path + "/"
		guard lexicalCandidate.path == lexicalRoot.path
			|| lexicalCandidate.path.hasPrefix(lexicalPrefix) else {
			throw LocalFileLocationError.invalidRelativePath(
				candidate.path
			)
		}
		let resolvedRoot = root.standardizedFileURL
			.resolvingSymlinksInPath()
		let rootPrefix = resolvedRoot.path.hasSuffix("/")
			? resolvedRoot.path
			: resolvedRoot.path + "/"
		let relativePath = lexicalCandidate.path == lexicalRoot.path
			? ""
			: String(lexicalCandidate.path.dropFirst(lexicalPrefix.count))
		var lexicalCurrent = lexicalRoot
		var safeCurrent = resolvedRoot
		for component in relativePath.split(separator: "/") {
			lexicalCurrent.appendPathComponent(String(component))
			let resolvedComponent = lexicalCurrent
				.resolvingSymlinksInPath()
			if resolvedComponent.path != lexicalCurrent.path
				|| FileManager.default.fileExists(
					atPath: lexicalCurrent.path
				) {
				safeCurrent = resolvedComponent
			} else {
				safeCurrent.appendPathComponent(String(component))
			}
			guard safeCurrent.path == resolvedRoot.path
				|| safeCurrent.path.hasPrefix(rootPrefix) else {
				throw LocalFileLocationError.invalidRelativePath(
					candidate.path
				)
			}
		}
		return safeCurrent
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
	public private(set) var loadError: LocalFileLocationLoadError?

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
		let loaded = Self.load(fileURL: fileURL)
		locations = loaded.locations
		loadError = loaded.error
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

	private static func load(
		fileURL: URL
	) -> (
		locations: [LocalFileLocation],
		error: LocalFileLocationLoadError?
	) {
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			return ([], nil)
		}
		let data: Data
		do {
			data = try Data(contentsOf: fileURL)
		} catch {
			return ([], .unreadable(error.localizedDescription))
		}
		do {
			return (
				try JSONDecoder().decode(
					[LocalFileLocation].self,
					from: data
				),
				nil
			)
		} catch {
			return ([], .invalidData(error.localizedDescription))
		}
	}

	private func persist() throws {
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let data = try JSONEncoder().encode(locations)
		try data.write(to: fileURL, options: [.atomic])
		loadError = nil
	}
}
#endif
