import Foundation

public actor ManagedKeyStore {
    public enum Error: Swift.Error, Equatable {
        case tooLarge
        case unsafePath
        case writeFailed(String)
        case deleteFailed(String)
		case wipeFailed(String)
    }

    public static let maxBytes = 1_000_000

    private let rootURL: URL

    public init(rootURL: URL = ManagedKeyStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Caterm/keys", isDirectory: true)
    }

    public nonisolated func path(hostId: UUID) -> URL {
        rootURL.appendingPathComponent(hostId.uuidString, isDirectory: false)
    }

    public nonisolated func read(hostId: UUID) throws -> Data? {
        let url = path(hostId: hostId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(hostId: UUID, bytes: Data) throws -> URL {
        guard bytes.count <= Self.maxBytes else { throw Error.tooLarge }
        try ensureRoot()
        let target = path(hostId: hostId)

        // Reject symlink at the target (path-traversal guard).
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw Error.unsafePath
        }

        let tmp = rootURL.appendingPathComponent(
            ".tmp.\(hostId.uuidString).\(UInt64.random(in: .min ... .max))",
            isDirectory: false
        )
        // Reject any tmp path that resolves outside root after symlink resolution.
        let resolvedTmp = tmp.standardized
        guard resolvedTmp.path.hasPrefix(rootURL.standardized.path) else { throw Error.unsafePath }

        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw Error.writeFailed("open: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try bytes.withUnsafeBytes { buf in
            var written = 0
            while written < buf.count {
                let n = Foundation.write(fd, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n <= 0 { throw Error.writeFailed("write: \(String(cString: strerror(errno)))") }
                written += n
            }
        }
        if fsync(fd) != 0 { throw Error.writeFailed("fsync: \(String(cString: strerror(errno)))") }

        if rename(tmp.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.writeFailed("rename: \(String(cString: strerror(errno)))")
        }
        return target
    }

    public func delete(hostId: UUID) throws {
        do {
            try FileManager.default.removeItem(at: path(hostId: hostId))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw Error.deleteFailed(error.localizedDescription)
        }
    }

	public func wipeAll() throws {
		do {
			try FileManager.default.removeItem(at: rootURL)
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			return
		} catch {
			throw Error.wipeFailed(error.localizedDescription)
		}
    }

    private func ensureRoot() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try fm.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        }
    }
}
