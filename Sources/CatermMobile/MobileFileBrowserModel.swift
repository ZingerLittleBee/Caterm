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

public struct MobileRemoteFileName: Equatable, Sendable {
	public let rawValue: String

	public init(_ rawValue: String) throws {
		guard !rawValue.isEmpty else {
			throw RemoteFileError.invalidName(reason: "Enter a name.")
		}
		guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
			throw RemoteFileError.invalidName(
				reason: "Names cannot start or end with whitespace."
			)
		}
		guard rawValue != ".", rawValue != ".." else {
			throw RemoteFileError.invalidName(reason: "Choose a name other than “.” or “..”.")
		}
		guard !rawValue.contains("/"),
			rawValue.rangeOfCharacter(from: .controlCharacters) == nil else {
			throw RemoteFileError.invalidName(
				reason: "Names cannot contain a slash or control character."
			)
		}
		guard rawValue.utf8.count <= 255 else {
			throw RemoteFileError.invalidName(
				reason: "Names must be 255 UTF-8 bytes or fewer."
			)
		}
		self.rawValue = rawValue
	}
}

public enum MobileFileMutation: Equatable, Sendable {
	case createFolder(name: String)
	case rename(from: String, to: String)
	case delete(name: String, isDirectory: Bool)

	public var progressDescription: String {
		switch self {
		case .createFolder(let name): "Creating \(name)…"
		case .rename(let oldName, let newName): "Renaming \(oldName) to \(newName)…"
		case .delete(let name, _): "Deleting \(name)…"
		}
	}

	fileprivate var failureTitle: String {
		switch self {
		case .createFolder: "Couldn’t Create Folder"
		case .rename: "Couldn’t Rename Item"
		case .delete(_, let isDirectory):
			isDirectory ? "Couldn’t Delete Folder" : "Couldn’t Delete File"
		}
	}
}

public struct MobileFileMutationFailure: Equatable, Sendable {
	public let title: String
	public let message: String
	public let recoverySuggestion: String
	public let canRetry: Bool
	public let recoveryActionTitle: String?
}

public struct MobileFileActionContext: Equatable, Sendable {
	public let host: SSHHost
	public let parentPath: String

	public init(host: SSHHost, parentPath: String) {
		self.host = host
		self.parentPath = parentPath
	}

	fileprivate var operationContext: MobileFileOperationContext {
		MobileFileOperationContext(hostID: host.id, parentPath: parentPath)
	}
}

private struct MobileFileOperationContext: Equatable, Sendable {
	let hostID: UUID
	let parentPath: String
}

private struct MobileFileMutationTarget: Equatable, Sendable {
	let context: MobileFileOperationContext
	let entryID: RemoteEntry.ID
	let sourcePath: String
	let name: String
	let type: RemoteEntryType
}

private enum PendingMobileFileMutation: Equatable, Sendable {
	case create(context: MobileFileOperationContext, name: String)
	case rename(target: MobileFileMutationTarget, name: String)
	case delete(target: MobileFileMutationTarget)

	var context: MobileFileOperationContext {
		switch self {
		case .create(let context, _): context
		case .rename(let target, _), .delete(let target): target.context
		}
	}

	var mutation: MobileFileMutation {
		switch self {
		case .create(_, let name): .createFolder(name: name)
		case .rename(let target, let name): .rename(from: target.name, to: name)
		case .delete(let target):
			.delete(name: target.name, isDirectory: target.type == .directory)
		}
	}
}

private enum MobileFileRetry: Equatable, Sendable {
	case mutation(PendingMobileFileMutation)
	case refresh(MobileFileOperationContext)
}

@MainActor
public final class MobileFileBrowserController: ObservableObject {
	@Published public private(set) var model: MobileFileBrowserModel
	@Published public private(set) var entries: [RemoteEntry]
	@Published public private(set) var state: MobileFileBrowserState
	@Published public private(set) var mutation: MobileFileMutation?
	@Published public private(set) var mutationFailure: MobileFileMutationFailure?
	@Published public var selectedHostID: UUID?

	private let factory: MobileRemoteFileClientFactory
	private var client: (any MobileRemoteFileSession)?
	private var clientHostID: UUID?
	private var loadTask: Task<Void, Never>?
	private var loadGeneration = 0
	private var mutationTask: Task<Void, Never>?
	private var mutationGeneration = 0
	private var retryAction: MobileFileRetry?

	public init(
		factory: MobileRemoteFileClientFactory,
		entries: [RemoteEntry] = []
	) {
		self.factory = factory
		self.model = MobileFileBrowserModel()
		self.entries = entries
		self.state = entries.isEmpty ? .idle : .loaded
		self.mutation = nil
		self.mutationFailure = nil
	}

	deinit {
		loadTask?.cancel()
		mutationTask?.cancel()
	}

	public func select(host: SSHHost) {
		guard selectedHostID != host.id || clientHostID != host.id else { return }
		let mutationCleanup = cancelMutationForContextChange()
		selectedHostID = host.id
		model = MobileFileBrowserModel()
		entries = []
		let previous = client
		client = nil
		clientHostID = nil
		startLoad(host: host) {
			await mutationCleanup?.value
			await previous?.disconnect()
		}
	}

	public func refresh(host: SSHHost) async {
		guard mutation == nil else { return }
		startLoad(host: host)
		await loadTask?.value
	}

	public func activate(_ entry: RemoteEntry, host: SSHHost) {
		guard entry.isDirectory else { return }
		let mutationCleanup = cancelMutationForContextChange()
		model.activate(entry)
		startLoad(host: host) { await mutationCleanup?.value }
	}

	public func goUp(host: SSHHost) {
		let mutationCleanup = cancelMutationForContextChange()
		model.goUp()
		startLoad(host: host) { await mutationCleanup?.value }
	}

	public func disconnect() {
		let mutationCleanup = cancelMutationForContextChange()
		loadGeneration += 1
		loadTask?.cancel()
		let client = client
		self.client = nil
		clientHostID = nil
		state = .disconnected
		Task {
			await mutationCleanup?.value
			await client?.disconnect()
		}
	}

	public func actionContext(host: SSHHost) -> MobileFileActionContext? {
		guard let context = try? currentContext(host: host) else { return nil }
		return MobileFileActionContext(host: host, parentPath: context.parentPath)
	}

	public func createFolder(
		named rawName: String,
		context: MobileFileActionContext
	) async {
		guard mutationTask == nil else { return }
		do {
			let name = try MobileRemoteFileName(rawName).rawValue
			let operationContext = try currentContext(context)
			await run(
				.create(context: operationContext, name: name),
				host: context.host
			)
		} catch {
			retryAction = nil
			publishMutationFailure(error, mutation: .createFolder(name: rawName))
		}
	}

	public func rename(
		_ entry: RemoteEntry,
		to rawName: String,
		context: MobileFileActionContext
	) async {
		guard mutationTask == nil else { return }
		do {
			let name = try MobileRemoteFileName(rawName).rawValue
			guard name != entry.name else { return }
			let target = try currentTarget(entry, context: context)
			await run(.rename(target: target, name: name), host: context.host)
		} catch {
			retryAction = nil
			publishMutationFailure(
				error,
				mutation: .rename(from: entry.name, to: rawName)
			)
		}
	}

	public func delete(
		_ entry: RemoteEntry,
		context: MobileFileActionContext
	) async {
		guard mutationTask == nil else { return }
		do {
			guard entry.type != .unknown else {
				throw RemoteFileError.invalidResponse(
					message: "Caterm cannot determine whether this remote item is a file or folder."
				)
			}
			let target = try currentTarget(entry, context: context)
			await run(.delete(target: target), host: context.host)
		} catch {
			retryAction = nil
			publishMutationFailure(
				error,
				mutation: .delete(name: entry.name, isDirectory: entry.isDirectory)
			)
		}
	}

	public func retryMutation(host: SSHHost) async {
		guard let retryAction else { return }
		switch retryAction {
		case .mutation(let pending):
			await run(pending, host: host)
		case .refresh(let context):
			await refreshAfterCompletedMutation(context: context, host: host)
		}
	}

	public func dismissMutationFailure() {
		mutationFailure = nil
	}

	private func run(_ pending: PendingMobileFileMutation, host: SSHHost) async {
		guard mutationTask == nil else { return }
		mutationGeneration += 1
		let generation = mutationGeneration
		mutation = pending.mutation
		mutationFailure = nil
		retryAction = nil
		let task = Task { [weak self] in
			guard let self else { return }
			await self.perform(pending, host: host, generation: generation)
		}
		mutationTask = task
		await task.value
		if generation == mutationGeneration {
			mutationTask = nil
		}
	}

	private func perform(
		_ pending: PendingMobileFileMutation,
		host: SSHHost,
		generation: Int
	) async {
		do {
			try ensureCurrent(pending, host: host, generation: generation)
			let operationClient = try await client(
				for: host,
				generation: loadGeneration
			)
			switch pending {
			case .create(let context, let name):
				try await operationClient.createDirectory(
					context.parentPath.appendingRemotePathComponent(name)
				)
			case .rename(let target, let name):
				try await operationClient.rename(
					from: target.sourcePath,
					to: target.context.parentPath.appendingRemotePathComponent(name)
				)
			case .delete(let target):
				try await operationClient.delete(
					target.sourcePath,
					isDirectory: target.type == .directory
				)
			}
			try Task.checkCancellation()
			try ensureCurrent(pending, host: host, generation: generation)
			await refreshAfterCompletedMutation(
				context: pending.context,
				host: host,
				generation: generation
			)
		} catch is CancellationError {
			clearMutationIfCurrent(generation: generation)
		} catch RemoteFileError.cancelled {
			clearMutationIfCurrent(generation: generation)
		} catch {
			guard generation == mutationGeneration else { return }
			mutation = nil
			retryAction = retryAction(for: error, pending: pending)
			publishMutationFailure(error, mutation: pending.mutation)
			invalidateClientIfNeeded(error)
		}
	}

	private func refreshAfterCompletedMutation(
		context: MobileFileOperationContext,
		host: SSHHost,
		generation: Int? = nil
	) async {
		let expectedGeneration = generation ?? mutationGeneration
		do {
			let activeContext = try currentContext(host: host)
			guard context == activeContext else {
				throw RemoteFileError.staleOperation
			}
			let operationClient = try await client(
				for: host,
				generation: loadGeneration
			)
			let loaded = try await operationClient.list(context.parentPath)
			try Task.checkCancellation()
			let refreshedContext = try currentContext(host: host)
			guard context == refreshedContext,
				expectedGeneration == mutationGeneration else {
				throw RemoteFileError.staleOperation
			}
			entries = loaded
			state = .loaded
			mutation = nil
			mutationFailure = nil
			retryAction = nil
		} catch is CancellationError {
			clearMutationIfCurrent(generation: expectedGeneration)
		} catch RemoteFileError.cancelled {
			clearMutationIfCurrent(generation: expectedGeneration)
		} catch {
			guard expectedGeneration == mutationGeneration else { return }
			mutation = nil
			retryAction = .refresh(context)
			mutationFailure = MobileFileMutationFailure(
				title: "Refresh Failed",
				message: error.localizedDescription,
				recoverySuggestion: "Reconnect and refresh this folder. Caterm will not repeat the file action.",
				canRetry: true,
				recoveryActionTitle: "Refresh"
			)
			invalidateClientIfNeeded(error)
		}
	}

	private func currentContext(host: SSHHost) throws -> MobileFileOperationContext {
		guard selectedHostID == host.id, state == .loaded else {
			throw RemoteFileError.staleOperation
		}
		return MobileFileOperationContext(hostID: host.id, parentPath: model.path)
	}

	private func currentContext(
		_ actionContext: MobileFileActionContext
	) throws -> MobileFileOperationContext {
		let context = try currentContext(host: actionContext.host)
		guard context == actionContext.operationContext else {
			throw RemoteFileError.staleOperation
		}
		return context
	}

	private func currentTarget(
		_ entry: RemoteEntry,
		context actionContext: MobileFileActionContext
	) throws -> MobileFileMutationTarget {
		let context = try currentContext(actionContext)
		guard entries.contains(where: {
			$0.id == entry.id && $0.name == entry.name && $0.type == entry.type
		}) else {
			throw RemoteFileError.staleOperation
		}
		return MobileFileMutationTarget(
			context: context,
			entryID: entry.id,
			sourcePath: context.parentPath.appendingRemotePathComponent(entry.name),
			name: entry.name,
			type: entry.type
		)
	}

	private func ensureCurrent(
		_ pending: PendingMobileFileMutation,
		host: SSHHost,
		generation: Int
	) throws {
		let context = try currentContext(host: host)
		guard generation == mutationGeneration,
			pending.context == context else {
			throw RemoteFileError.staleOperation
		}
		switch pending {
		case .create:
			return
		case .rename(let target, _), .delete(let target):
			guard entries.contains(where: {
				$0.id == target.entryID && $0.name == target.name && $0.type == target.type
			}) else {
				throw RemoteFileError.staleOperation
			}
		}
	}

	private func clearMutationIfCurrent(generation: Int) {
		guard generation == mutationGeneration else { return }
		mutation = nil
	}

	private func cancelMutationForContextChange() -> Task<Void, Never>? {
		let pendingMutation = mutationTask
		let operationClient = pendingMutation == nil ? nil : client
		mutationGeneration += 1
		pendingMutation?.cancel()
		mutationTask = nil
		mutation = nil
		mutationFailure = nil
		retryAction = nil
		guard let pendingMutation else { return nil }
		client = nil
		clientHostID = nil
		return Task {
			await pendingMutation.value
			await operationClient?.disconnect()
		}
	}

	private func publishMutationFailure(_ error: Error, mutation: MobileFileMutation) {
		let remoteError = error as? RemoteFileError
		let details: (String, String, Bool) = switch remoteError {
		case .invalidName(let reason): (reason, "Edit the name and try again.", false)
		case .conflict: (error.localizedDescription, "Choose a different name.", false)
		case .directoryNotEmpty:
			(error.localizedDescription, "Delete the folder’s contents first.", true)
		case .notFound:
			(error.localizedDescription, "Refresh the folder before trying again.", true)
		case .permissionDenied:
			(error.localizedDescription, "Check remote permissions and try again.", true)
		case .sessionUnavailable:
			(error.localizedDescription, "Reconnect and try the action again.", true)
		case .staleOperation:
			(error.localizedDescription, "Open the Host and folder again before retrying.", false)
		default: (error.localizedDescription, "Check the connection and try again.", true)
		}
		let recoveryActionTitle: String? = switch retryAction {
		case .mutation: "Retry"
		case .refresh: "Refresh"
		case nil: nil
		}
		mutationFailure = MobileFileMutationFailure(
			title: mutation.failureTitle,
			message: details.0,
			recoverySuggestion: details.1,
			canRetry: details.2 && recoveryActionTitle != nil,
			recoveryActionTitle: recoveryActionTitle
		)
	}

	private func retryAction(
		for error: Error,
		pending: PendingMobileFileMutation
	) -> MobileFileRetry? {
		switch error as? RemoteFileError {
		case .conflict, .directoryNotEmpty, .invalidName, .staleOperation,
		     .cancelled, .unsupported, .localIO:
			return nil
		case .notFound, .sessionUnavailable, .hostKeyChanged,
		     .hostKeyPersistenceFailed, .transport, .invalidResponse,
		     .cleanupFailed:
			return .refresh(pending.context)
		case .permissionDenied:
			return .mutation(pending)
		case nil:
			return .refresh(pending.context)
		}
	}

	private func invalidateClientIfNeeded(_ error: Error) {
		guard error is CancellationError
			|| error as? RemoteFileError == .cancelled
			|| error as? RemoteFileError == .sessionUnavailable else { return }
		let disconnected = client
		client = nil
		clientHostID = nil
		Task { await disconnected?.disconnect() }
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

extension String {
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
