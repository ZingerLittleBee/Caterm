import Combine
import FileTransferStore
import Foundation
import SSHCommandBuilder

public enum MobileFileBrowserPresentation: Equatable {
	case download(path: String)
	case confirmDelete(path: String, isDirectory: Bool)
	case rename(path: String, currentName: String)
}

public enum MobileFileBrowserState: Equatable {
	case idle
	case connecting
	case loaded
	case permissionDenied(String)
	case disconnected
	case trustFailure(String)
	case failed(String)
}

@MainActor
public final class MobileFileBrowserController: ObservableObject {
	@Published public private(set) var model: MobileFileBrowserModel
	@Published public private(set) var entries: [RemoteEntry]
	@Published public private(set) var state: MobileFileBrowserState
	@Published public var selectedHostID: UUID?

	private let factory: MobileRemoteFileClientFactory
	private var client: (any MobileRemoteFileSession)?
	private var clientHostID: UUID?
	private var loadTask: Task<Void, Never>?
	private var loadGeneration = 0

	public init(
		factory: MobileRemoteFileClientFactory,
		entries: [RemoteEntry] = []
	) {
		self.factory = factory
		self.model = MobileFileBrowserModel()
		self.entries = entries
		self.state = entries.isEmpty ? .idle : .loaded
	}

	deinit { loadTask?.cancel() }

	public func select(host: SSHHost) {
		guard selectedHostID != host.id || clientHostID != host.id else { return }
		selectedHostID = host.id
		model = MobileFileBrowserModel()
		entries = []
		let previous = client
		client = nil
		clientHostID = nil
		startLoad(host: host) {
			await previous?.disconnect()
		}
	}

	public func refresh(host: SSHHost) async {
		startLoad(host: host)
		await loadTask?.value
	}

	public func activate(_ entry: RemoteEntry, host: SSHHost) {
		guard entry.isDirectory else { return }
		model.activate(entry)
		startLoad(host: host)
	}

	public func goUp(host: SSHHost) {
		model.goUp()
		startLoad(host: host)
	}

	public func disconnect() {
		loadGeneration += 1
		loadTask?.cancel()
		let client = client
		self.client = nil
		clientHostID = nil
		state = .disconnected
		Task { await client?.disconnect() }
	}

	private func startLoad(
		host: SSHHost,
		beforeLoad: @escaping @MainActor () async -> Void = {}
	) {
		let previous = loadTask
		previous?.cancel()
		loadGeneration += 1
		let generation = loadGeneration
		let requestedPath = model.path
		loadTask = Task { [weak self] in
			await previous?.value
			guard !Task.isCancelled, let self else { return }
			await beforeLoad()
			guard !Task.isCancelled else { return }
			await self.load(
				host: host,
				path: requestedPath,
				generation: generation
			)
		}
	}

	private func load(host: SSHHost, path: String, generation: Int) async {
		guard requestIsCurrent(host: host, path: path, generation: generation) else {
			return
		}
		state = .connecting
		do {
			let client = try await client(for: host, generation: generation)
			let loaded = try await client.list(path)
			try Task.checkCancellation()
			guard requestIsCurrent(host: host, path: path, generation: generation) else {
				return
			}
			entries = loaded
			state = .loaded
		} catch is CancellationError {
			return
		} catch RemoteFileError.cancelled {
			return
		} catch RemoteFileError.permissionDenied(let message) {
			guard requestIsCurrent(host: host, path: path, generation: generation) else { return }
			state = .permissionDenied(message)
		} catch RemoteFileError.sessionUnavailable {
			guard requestIsCurrent(host: host, path: path, generation: generation) else { return }
			state = .disconnected
			client = nil
			clientHostID = nil
		} catch RemoteFileError.hostKeyChanged(let endpoint) {
			guard requestIsCurrent(host: host, path: path, generation: generation) else { return }
			state = .trustFailure("The SSH host key changed for \(endpoint).")
			client = nil
			clientHostID = nil
		} catch RemoteFileError.hostKeyPersistenceFailed(let endpoint) {
			guard requestIsCurrent(host: host, path: path, generation: generation) else { return }
			state = .trustFailure(
				"Caterm could not save the SSH host key for \(endpoint)."
			)
			client = nil
			clientHostID = nil
		} catch {
			guard requestIsCurrent(host: host, path: path, generation: generation) else { return }
			state = .failed(error.localizedDescription)
		}
	}

	private func client(
		for host: SSHHost,
		generation: Int
	) async throws -> any MobileRemoteFileSession {
		if let client, clientHostID == host.id { return client }
		let created = try await factory.make(host)
		guard generation == loadGeneration, selectedHostID == host.id else {
			await created.disconnect()
			throw CancellationError()
		}
		client = created
		clientHostID = host.id
		return created
	}

	private func requestIsCurrent(
		host: SSHHost,
		path: String,
		generation: Int
	) -> Bool {
		generation == loadGeneration
			&& selectedHostID == host.id
			&& model.path == path
	}
}

public struct MobileFileBrowserModel: Equatable {
	public var path: String
	public var presentation: MobileFileBrowserPresentation?

	public init(path: String = "~", presentation: MobileFileBrowserPresentation? = nil) {
		self.path = path.isEmpty ? "~" : path
		self.presentation = presentation
	}

	public mutating func activate(_ entry: RemoteEntry) {
		let childPath = path.appendingRemotePathComponent(entry.name)
		if entry.isDirectory {
			path = childPath
			presentation = nil
		} else {
			presentation = .download(path: childPath)
		}
	}

	public mutating func goUp() {
		path = path.remoteParentPath
		presentation = nil
	}

	public mutating func requestDelete(_ entry: RemoteEntry) {
		presentation = .confirmDelete(
			path: path.appendingRemotePathComponent(entry.name),
			isDirectory: entry.isDirectory
		)
	}

	public mutating func requestRename(_ entry: RemoteEntry) {
		presentation = .rename(
			path: path.appendingRemotePathComponent(entry.name),
			currentName: entry.name
		)
	}
}

private extension String {
	func appendingRemotePathComponent(_ component: String) -> String {
		let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !trimmedComponent.isEmpty else { return self }
		switch self {
		case "~":
			return "\(self)/\(trimmedComponent)"
		case "/":
			return "/\(trimmedComponent)"
		default:
			if hasPrefix("/") {
				return "/\(trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(trimmedComponent)"
			}
			return "\(trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(trimmedComponent)"
		}
	}

	var remoteParentPath: String {
		guard self != "/", self != "~" else { return self }
		if hasPrefix("~/") {
			let suffix = String(dropFirst(2))
			guard let slashIndex = suffix.lastIndex(of: "/") else { return "~" }
			return "~/" + suffix[..<slashIndex]
		}
		let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard let slashIndex = trimmed.lastIndex(of: "/") else { return "/" }
		return "/" + trimmed[..<slashIndex]
	}
}
