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

	/// A UUID encoded as unpadded base64 occupies 22 bytes.
	public static let socketTokenBytes = 22

	/// Returns a protected ControlMaster directory in the user's temporary area.
	///
	/// Foundation resolves the temporary root to a sandbox-accessible,
	/// user-scoped location. SSH children use this directory as their working
	/// directory and receive only a relative socket name, so a long sandbox
	/// container path never enters Darwin's fixed-size `sun_path`. The
	/// product-scoped directory avoids collisions with unrelated temporary
	/// data, while mode 0700 protects the sockets. `root` is injectable for
	/// deterministic tests.
	public static func controlMasterDir(
		root: URL? = nil
	) throws -> URL {
		let ownerID = getuid()
		let base = root ?? FileManager.default.temporaryDirectory
		let directory = base.appendingPathComponent(
			"caterm-cm",
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
