import Darwin
import Foundation

public enum CacheDirectoryError: Error {
	case unsafeControlMasterDirectory(URL)
}

public enum CacheDirectories {
	/// Darwin's `sockaddr_un.sun_path` stores 104 bytes including the NUL.
	public static let unixSocketPathMaxBytes = 103

	/// OpenSSH creates the master at a temporary suffixed path before rename.
	public static let openSSHTemporarySuffixBytes = 16

	/// Returns a short, user-scoped ControlMaster directory under `/tmp`.
	///
	/// OpenSSH appends a temporary suffix while creating a multiplex socket.
	/// A home-relative cache path can therefore exceed `sun_path` even when
	/// the final `.sock` path appears to fit. The user ID keeps the directory
	/// isolated across local accounts, while mode 0700 protects its contents.
	/// `root` and `userID` are injectable for deterministic tests.
	public static func controlMasterDir(
		root: URL? = nil,
		userID: UInt32? = nil
	) throws -> URL {
		let ownerID = getuid()
		let namespaceID = userID ?? ownerID
		let base = root ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
		let directory = base.appendingPathComponent(
			"caterm-cm-\(namespaceID)",
			isDirectory: true
		)
		try validateExistingDirectory(directory, ownerID: ownerID)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try validateExistingDirectory(directory, ownerID: ownerID)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: directory.path
		)
		return directory
	}

	private static func validateExistingDirectory(
		_ directory: URL,
		ownerID: uid_t
	) throws {
		var info = stat()
		guard lstat(directory.path, &info) == 0 else {
			if errno == ENOENT { return }
			throw CocoaError(.fileReadUnknown)
		}
		let fileType = info.st_mode & mode_t(S_IFMT)
		guard fileType == mode_t(S_IFDIR), info.st_uid == ownerID else {
			throw CacheDirectoryError.unsafeControlMasterDirectory(directory)
		}
	}
}
