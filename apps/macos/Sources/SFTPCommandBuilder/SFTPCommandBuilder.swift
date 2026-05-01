import Foundation
import SSHCommandBuilder

public struct SFTPInvocation: Equatable {
	public let argv: [String]
	public let environment: [String: String]
	public let scriptStdin: String
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

		// No-fallback options FIRST (first-value-wins under OpenSSH).
		argv += ["-o", "ControlMaster=no"]
		argv += ["-o", "BatchMode=yes"]
		argv += ["-o", "PreferredAuthentications=none"]
		argv += ["-o", "ProxyCommand=none"]

		// Master socket
		argv += ["-o", "ControlPath=\(controlPath.path)"]
		argv += ["-o", "ControlPersist=10m"]

		// Policy parity
		argv += ["-o", "StrictHostKeyChecking=\(credentials.strictHostKeyChecking.rawValue)"]
		argv += ["-o", "UserKnownHostsFile=\(credentials.knownHostsCaterm.path) \(credentials.knownHostsUser.path)"]
		for id in credentials.identityFiles {
			argv += ["-i", id.path]
		}

		// Filtered extras (case-insensitive denylist).
		for (k, v) in credentials.extraSSHOptions.sorted(by: { $0.key < $1.key }) {
			if SFTPCredentialsDenylist.contains(k.lowercased()) { continue }
			argv += ["-o", "\(k)=\(v)"]
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

		var env: [String: String] = [:]
		if let askpass = credentials.askpassPath {
			env["SSH_ASKPASS"] = askpass.path
			env["SSH_ASKPASS_REQUIRE"] = "force"
			env["CATERM_HOST_ID"] = host.id.uuidString
		}

		return SFTPInvocation(argv: argv, environment: env, scriptStdin: script)
	}

	private static func makeScript(_ op: SFTPOperation) throws -> String {
		switch op {
		case .list(let dir):
			return "cd \(try SFTPPathEncoder.encode(dir))\nls -la\nexit\n"
		case .put(let local, let remote, let r, let resume):
			let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
			return "put \(flags) \(try SFTPPathEncoder.encode(local.path)) \(try SFTPPathEncoder.encode(remote))\nexit\n"
		case .get(let remote, let local, let r, let resume):
			let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
			return "get \(flags) \(try SFTPPathEncoder.encode(remote)) \(try SFTPPathEncoder.encode(local.path))\nexit\n"
		case .mkdir(let p):
			return "mkdir \(try SFTPPathEncoder.encode(p))\nexit\n"
		case .remove(let p, let isDir):
			let cmd = isDir ? "rmdir" : "rm"
			return "\(cmd) \(try SFTPPathEncoder.encode(p))\nexit\n"
		case .rename(let a, let b):
			return "rename \(try SFTPPathEncoder.encode(a)) \(try SFTPPathEncoder.encode(b))\nexit\n"
		}
	}
}
