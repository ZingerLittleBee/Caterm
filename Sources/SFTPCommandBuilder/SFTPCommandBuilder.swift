import Foundation
import SSHCommandBuilder

public struct SFTPInvocation: Equatable, Sendable {
	public let argv: [String]
	public let environment: [String: String]
	public let scriptStdin: String

	public init(argv: [String], environment: [String: String], scriptStdin: String) {
		self.argv = argv
		self.environment = environment
		self.scriptStdin = scriptStdin
	}
}

public enum SFTPOperation {
	case list(remoteDir: String)
	case put(localPath: URL, remotePath: String, recursive: Bool, resume: Bool)
	case get(remotePath: String, localPath: URL, recursive: Bool, resume: Bool)
	case mkdir(remotePath: String)
	case remove(remotePath: String, isDirectory: Bool)
	case rename(from: String, to: String)
}

private let kSftpMaxLine = 1023

public enum SFTPCommandBuilder {
	public static func invocation(
		host: SSHHost,
		controlPath: URL,
		credentials: SFTPCredentials,
		operation: SFTPOperation
	) throws -> SFTPInvocation {
		var argv: [String] = ["/usr/bin/sftp"]

		// No-fallback options stay first because OpenSSH uses the first value.
		let socketOptions = SSHConnectionPolicy.existingControlSocketPlan(
			controlPath: controlPath.path,
			strictHostKeyChecking: credentials.strictHostKeyChecking.rawValue,
			knownHostsFiles: [
				credentials.knownHostsCaterm.path,
				credentials.knownHostsUser.path,
			]
		)
		for option in socketOptions {
			argv += try option.invocationArguments()
		}

		// Filtered extras (case-insensitive denylist).
		for (k, v) in credentials.extraSSHOptions.sorted(by: { $0.key < $1.key }) {
			if SFTPCredentialsDenylist.contains(k.lowercased()) { continue }
			argv += try SSHOption.option(k, v).invocationArguments()
		}

		// Batch script + destination
		argv += ["-b", "/dev/stdin"]
		argv += ["-P", String(host.port)]
		argv += ["\(host.username)@\(host.hostname)"]

		// Build script and validate line lengths.
		let script = try makeScript(operation)
		for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
			let bytes = line.utf8.count
			if bytes > kSftpMaxLine {
				throw SFTPBatchLineError.lineTooLong(bytes: bytes, limit: kSftpMaxLine)
			}
		}

		return SFTPInvocation(argv: argv, environment: [:], scriptStdin: script)
	}

	private static func makeScript(_ op: SFTPOperation) throws -> String {
		switch op {
		case .list(let dir):
			return "cd \(try SFTPPathEncoder.encodeRemote(dir))\nls -la\nexit\n"
		case .put(let local, let remote, let r, let resume):
			let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
			return "put \(flags) \(try SFTPPathEncoder.encode(local.path)) \(try SFTPPathEncoder.encodeRemote(remote))\nexit\n"
		case .get(let remote, let local, let r, let resume):
			let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
			return "get \(flags) \(try SFTPPathEncoder.encodeRemote(remote)) \(try SFTPPathEncoder.encode(local.path))\nexit\n"
		case .mkdir(let p):
			return "mkdir \(try SFTPPathEncoder.encodeRemote(p))\nexit\n"
		case .remove(let p, let isDir):
			let cmd = isDir ? "rmdir" : "rm"
			return "\(cmd) \(try SFTPPathEncoder.encodeRemote(p))\nexit\n"
		case .rename(let a, let b):
			return "rename \(try SFTPPathEncoder.encodeRemote(a)) \(try SFTPPathEncoder.encodeRemote(b))\nexit\n"
		}
	}
}
