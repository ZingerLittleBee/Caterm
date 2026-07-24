import Foundation

public enum RemoteEntryType: Equatable, Sendable {
	case file
	case directory
	case unknown
}

public struct RemoteEntry: Equatable, Identifiable, Sendable {
	public var id: String { canonicalPath ?? name }
	public let canonicalPath: String?
	public let name: String
	public let type: RemoteEntryType
	public var isDirectory: Bool { type == .directory }
	public let size: Int64?
	public let mtime: Date?
	public let mode: UInt16?

	public init(
		name: String,
		isDirectory: Bool,
		size: Int64,
		mtime: Date?,
		mode: UInt16,
		canonicalPath: String? = nil
	) {
		self.canonicalPath = canonicalPath
		self.name = name
		self.type = isDirectory ? .directory : .file
		self.size = size
		self.mtime = mtime
		self.mode = mode
	}

	public init(
		name: String,
		type: RemoteEntryType,
		size: Int64?,
		mtime: Date?,
		mode: UInt16?,
		canonicalPath: String? = nil
	) {
		self.canonicalPath = canonicalPath
		self.name = name
		self.type = type
		self.size = size
		self.mtime = mtime
		self.mode = mode
	}
}

@available(*, deprecated, renamed: "RemoteFileError")
public typealias RemoteFileSystemError = RemoteFileError
