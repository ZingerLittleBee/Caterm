import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

public actor RemoteFileSystem {
	private let host: SSHHost
	private let controlPath: URL
	private let credentials: SFTPCredentials
	private let runner: SFTPRunner
	private let liveness: ControlMasterLiveness

	public init(host: SSHHost, controlPath: URL, credentials: SFTPCredentials,
	            runner: SFTPRunner = SystemSFTPRunner(),
	            liveness: ControlMasterLiveness) {
		self.host = host
		self.controlPath = controlPath
		self.credentials = credentials
		self.runner = runner
		self.liveness = liveness
	}

	public func list(_ path: String) async throws -> [RemoteEntry] {
		try await ensureAlive()
		let inv = try SFTPCommandBuilder.invocation(
			host: host, controlPath: controlPath,
			credentials: credentials, operation: .list(remoteDir: path)
		)
		let (out, code) = try await runner.run(inv)
		if code != 0 {
			throw RemoteFileSystemError.subprocessFailed(exitCode: code, stderrTail: tail(out))
		}
		return try parseLsOutput(out)
	}

	public func mkdir(_ path: String) async throws {
		try await ensureAlive()
		try await runVoidOp(.mkdir(remotePath: path))
	}

	public func remove(_ path: String, isDirectory: Bool) async throws {
		try await ensureAlive()
		try await runVoidOp(.remove(remotePath: path, isDirectory: isDirectory))
	}

	public func rename(from: String, to: String) async throws {
		try await ensureAlive()
		try await runVoidOp(.rename(from: from, to: to))
	}

	private func runVoidOp(_ op: SFTPOperation) async throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: host, controlPath: controlPath, credentials: credentials, operation: op)
		let (out, code) = try await runner.run(inv)
		if code != 0 {
			throw RemoteFileSystemError.subprocessFailed(exitCode: code, stderrTail: tail(out))
		}
	}

	private func ensureAlive() async throws {
		if !(await liveness.isAlive(hostId: host.id)) {
			throw RemoteFileSystemError.sessionGone
		}
	}

	private func tail(_ s: String) -> String { String(s.suffix(1024)) }
}

func parseLsOutput(_ stdout: String) throws -> [RemoteEntry] {
	// Each ls -la line: <perm> <links> <owner> <group> <size> <month> <day> <time/year> <name>
	// Skip lines that don't match (sftp prompts, blank lines, ".", "..").
	var out: [RemoteEntry] = []
	for raw in stdout.split(separator: "\n") {
		let line = raw.trimmingCharacters(in: .whitespaces)
		if line.isEmpty || line.hasPrefix("sftp>") { continue }
		let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		guard parts.count >= 9 else { continue }
		let perms = parts[0]
		guard let size = Int64(parts[4]) else { continue }
		let name = parts[8...].joined(separator: " ")
		if name == "." || name == ".." { continue }
		out.append(RemoteEntry(
			name: name,
			isDirectory: perms.first == "d",
			size: size,
			mtime: nil,
			mode: 0
		))
	}
	return out
}
