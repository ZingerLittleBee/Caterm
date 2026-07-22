import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

public actor RemoteFileSystem: RemoteFileClient {
	private let host: SSHHost
	private let controlPath: URL
	private let credentials: SFTPCredentials
	private let runner: SFTPRunner
	private let liveness: ControlMasterLiveness

	public init(host: SSHHost, controlPath: URL, credentials: SFTPCredentials,
	            runner: SFTPRunner = DefaultSFTPRunner(),
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
		let (out, code) = try await run(inv)
		if code != 0 {
			throw classifyFailure(output: out, exitCode: code)
		}
		return try parseLsOutput(out)
	}

	public func stat(_ path: String) async throws -> RemoteEntry? {
		let parent = remoteParent(of: path)
		let name = (path as NSString).lastPathComponent
		return try await list(parent).first { $0.name == name }
	}

	public func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		try await ensureAlive()
		let total = localByteCount(at: localURL)
		await progress(TransferProgress(bytesTransferred: 0, totalBytes: total))
		try await runVoidOp(.put(
			localPath: localURL,
			remotePath: remotePath,
			recursive: isDirectory,
			resume: resume
		))
		try Task.checkCancellation()
		let transferred = total ?? 0
		await progress(TransferProgress(
			bytesTransferred: transferred,
			totalBytes: total
		))
		return RemoteFileTransferResult(bytesTransferred: transferred)
	}

	public func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		try await ensureAlive()
		let total = try await stat(remotePath)?.size
		await progress(TransferProgress(bytesTransferred: 0, totalBytes: total))
		try await runVoidOp(.get(
			remotePath: remotePath,
			localPath: localURL,
			recursive: isDirectory,
			resume: resume
		))
		try Task.checkCancellation()
		let transferred = total ?? localByteCount(at: localURL) ?? 0
		await progress(TransferProgress(
			bytesTransferred: transferred,
			totalBytes: total
		))
		return RemoteFileTransferResult(bytesTransferred: transferred)
	}

	public func createDirectory(_ path: String) async throws {
		try await mkdir(path)
	}

	public func mkdir(_ path: String) async throws {
		try await ensureAlive()
		try await runVoidOp(.mkdir(remotePath: path))
	}

	public func remove(_ path: String, isDirectory: Bool) async throws {
		try await ensureAlive()
		try await runVoidOp(.remove(remotePath: path, isDirectory: isDirectory))
	}

	public func delete(_ path: String, isDirectory: Bool) async throws {
		try await remove(path, isDirectory: isDirectory)
	}

	public func rename(from: String, to: String) async throws {
		try await ensureAlive()
		try await runVoidOp(.rename(from: from, to: to))
	}

	private func runVoidOp(_ op: SFTPOperation) async throws {
		try Task.checkCancellation()
		let inv = try SFTPCommandBuilder.invocation(
			host: host, controlPath: controlPath, credentials: credentials, operation: op)
		let (out, code) = try await run(inv)
		try Task.checkCancellation()
		if code != 0 {
			throw classifyFailure(output: out, exitCode: code)
		}
	}

	private func run(_ invocation: SFTPInvocation) async throws -> (String, Int32) {
		do {
			return try await runner.run(invocation)
		} catch is CancellationError {
			throw RemoteFileError.cancelled
		} catch let error as RemoteFileError {
			throw error
		} catch {
			throw RemoteFileError.transport(message: String(describing: error))
		}
	}

	private func ensureAlive() async throws {
		if !(await liveness.isAlive(hostId: host.id)) {
			throw RemoteFileError.sessionUnavailable
		}
	}

	private func tail(_ s: String) -> String { String(s.suffix(1024)) }

	private func classifyFailure(output: String, exitCode: Int32) -> RemoteFileError {
		let detail = tail(output)
		let normalized = detail.lowercased()
		if normalized.contains("permission denied") {
			return .permissionDenied(message: detail)
		}
		if normalized.contains("no such file") || normalized.contains("not found") {
			return .notFound(path: detail)
		}
		return .transport(message: "SFTP exited with code \(exitCode): \(detail)")
	}

	private func remoteParent(of path: String) -> String {
		if path == "~" || path == "/" { return path }
		let parent = (path as NSString).deletingLastPathComponent
		return parent.isEmpty ? "." : parent
	}

	private func localByteCount(at url: URL) -> Int64? {
		guard let values = try? url.resourceValues(forKeys: [
			.fileSizeKey,
			.totalFileAllocatedSizeKey,
		]) else { return nil }
		return Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
	}
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
