import Foundation

public struct RemoteEntry: Equatable, Identifiable, Sendable {
	public var id: String { name }
	public let name: String
	public let isDirectory: Bool
	public let size: Int64
	public let mtime: Date?
	public let mode: UInt16

	public init(name: String, isDirectory: Bool, size: Int64, mtime: Date?, mode: UInt16) {
		self.name = name
		self.isDirectory = isDirectory
		self.size = size
		self.mtime = mtime
		self.mode = mode
	}
}

@available(*, deprecated, renamed: "RemoteFileError")
public typealias RemoteFileSystemError = RemoteFileError
