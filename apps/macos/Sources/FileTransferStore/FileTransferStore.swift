import Combine
import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

@MainActor
public final class FileTransferStore: ObservableObject {
	@Published public private(set) var tasks: [TransferTask] = []

	private let controlPathFor: (UUID) -> URL
	private let credentialsFor: (UUID) -> SFTPCredentials
	private let runner: SFTPRunner
	private let liveness: ControlMasterLiveness
	private var perHostQueues: [UUID: [TaskId]] = [:]
	private var perHostBusy: Set<UUID> = []
	private var perHostHost: [UUID: SSHHost] = [:]

	public init(controlPathFor: @escaping (UUID) -> URL,
	            credentialsFor: @escaping (UUID) -> SFTPCredentials,
	            runner: SFTPRunner = SystemSFTPRunner(),
	            liveness: ControlMasterLiveness) {
		self.controlPathFor = controlPathFor
		self.credentialsFor = credentialsFor
		self.runner = runner
		self.liveness = liveness
	}

	public func task(id: TaskId) -> TransferTask? { tasks.first { $0.id == id } }

	public func enqueueUpload(localPaths: [URL], remoteDir: String, host: SSHHost) -> [TaskId] {
		var ids: [TaskId] = []
		perHostHost[host.id] = host
		for p in localPaths {
			let isDir = (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
			let dest = (remoteDir as NSString).appendingPathComponent(p.lastPathComponent)
			let t = TransferTask(id: UUID(), kind: .upload, hostId: host.id,
			                     source: p.path, destination: dest, isDirectory: isDir,
			                     status: .pending, error: nil)
			tasks.append(t)
			perHostQueues[host.id, default: []].append(t.id)
			ids.append(t.id)
		}
		kick(host.id)
		return ids
	}

	public func enqueueDownload(remotePaths: [String], localDir: URL, host: SSHHost) -> [TaskId] {
		var ids: [TaskId] = []
		perHostHost[host.id] = host
		for r in remotePaths {
			let dest = localDir.appendingPathComponent((r as NSString).lastPathComponent)
			let t = TransferTask(id: UUID(), kind: .download, hostId: host.id,
			                     source: r, destination: dest.path, isDirectory: false,
			                     status: .pending, error: nil)
			tasks.append(t)
			perHostQueues[host.id, default: []].append(t.id)
			ids.append(t.id)
		}
		kick(host.id)
		return ids
	}

	public func cancel(_ id: TaskId) {
		guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
		if tasks[idx].status == .pending {
			tasks[idx].status = .cancelled
			if var q = perHostQueues[tasks[idx].hostId] {
				q.removeAll { $0 == id }
				perHostQueues[tasks[idx].hostId] = q
			}
		}
		// Mid-running cancel: future iteration; v1 only cancels pending.
	}

	public func retry(_ id: TaskId) {
		guard let idx = tasks.firstIndex(where: { $0.id == id }),
		      tasks[idx].status == .failed else { return }
		tasks[idx].status = .pending
		perHostQueues[tasks[idx].hostId, default: []].append(id)
		kick(tasks[idx].hostId)
	}

	public func waitIdle() async throws {
		// Tests-only: spin until all queues are empty and no host is busy.
		while perHostBusy.isEmpty == false || perHostQueues.values.contains(where: { !$0.isEmpty }) {
			try await Task.sleep(nanoseconds: 5_000_000)
		}
	}

	private func kick(_ hostId: UUID) {
		guard !perHostBusy.contains(hostId) else { return }
		guard let q = perHostQueues[hostId], let next = q.first else { return }
		perHostBusy.insert(hostId)
		perHostQueues[hostId]?.removeFirst()
		guard let idx = tasks.firstIndex(where: { $0.id == next }) else {
			perHostBusy.remove(hostId); return
		}
		tasks[idx].status = .running
		let task = tasks[idx]
		Task {
			await runTask(task)
			self.perHostBusy.remove(hostId)
			self.kick(hostId)
		}
	}

	private func runTask(_ t: TransferTask) async {
		guard let host = perHostHost[t.hostId] else {
			if let i = tasks.firstIndex(where: { $0.id == t.id }) {
				tasks[i].status = .failed
				tasks[i].error = "missing host registration"
			}
			return
		}
		let controlPath = controlPathFor(t.hostId)
		let creds = credentialsFor(t.hostId)
		let resume = t.error != nil  // retry path
		let op: SFTPOperation
		switch t.kind {
		case .upload:
			op = .put(localPath: URL(fileURLWithPath: t.source),
			          remotePath: t.destination, recursive: t.isDirectory, resume: resume)
		case .download:
			op = .get(remotePath: t.source,
			          localPath: URL(fileURLWithPath: t.destination), recursive: t.isDirectory, resume: resume)
		}
		do {
			let inv = try SFTPCommandBuilder.invocation(
				host: host, controlPath: controlPath, credentials: creds, operation: op)
			let (out, code) = try await runner.run(inv)
			if let i = self.tasks.firstIndex(where: { $0.id == t.id }) {
				if code == 0 {
					self.tasks[i].status = .completed
					self.tasks[i].error = nil
				} else {
					self.tasks[i].status = .failed
					self.tasks[i].error = String(out.suffix(1024))
				}
			}
		} catch {
			if let i = self.tasks.firstIndex(where: { $0.id == t.id }) {
				self.tasks[i].status = .failed
				self.tasks[i].error = "\(error)"
			}
		}
	}
}
