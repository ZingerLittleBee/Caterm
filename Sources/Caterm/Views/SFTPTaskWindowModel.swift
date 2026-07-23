import FileTransferStore
import Foundation
import SSHCommandBuilder

enum SFTPTaskSide: String, Codable, Hashable, Sendable {
	case left
	case right

	var opposite: SFTPTaskSide {
		self == .left ? .right : .left
	}
}

@MainActor
final class SFTPTaskWindowModel: ObservableObject {
	@Published private(set) var left = SFTPTaskPaneState()
	@Published private(set) var right = SFTPTaskPaneState()
	@Published private(set) var leftEntries: [SFTPTaskEntry] = []
	@Published private(set) var rightEntries: [SFTPTaskEntry] = []
	@Published private(set) var leftError: String?
	@Published private(set) var rightError: String?
	@Published private(set) var leftIsLoading = false
	@Published private(set) var rightIsLoading = false
	@Published private(set) var locations: [LocalFileLocation] = []
	@Published private(set) var transferNotice: String?

	private let locationStore: LocalFileLocationStore
	private var refreshRevisions: [SFTPTaskSide: UInt64] = [:]

	init(
		locationStore: LocalFileLocationStore =
			LocalFileLocationStore()
	) {
		self.locationStore = locationStore
	}

	func bootstrap(
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		await reloadLocations()
		if case .unconfigured = left.endpoint,
			let firstLocation = locations.first {
			left.setEndpoint(.local(locationID: firstLocation.id))
		}
		if case .unconfigured = right.endpoint, let firstHost = hosts.first {
			right.setEndpoint(.remote(hostID: firstHost.id))
		}
		await refresh(.left, hosts: hosts, transferStore: transferStore)
		await refresh(.right, hosts: hosts, transferStore: transferStore)
	}

	func state(for side: SFTPTaskSide) -> SFTPTaskPaneState {
		side == .left ? left : right
	}

	func entries(for side: SFTPTaskSide) -> [SFTPTaskEntry] {
		let pane = state(for: side)
		return pane.visibleEntries(
			in: side == .left ? leftEntries : rightEntries
		)
	}

	func error(for side: SFTPTaskSide) -> String? {
		side == .left ? leftError : rightError
	}

	func isLoading(_ side: SFTPTaskSide) -> Bool {
		side == .left ? leftIsLoading : rightIsLoading
	}

	func setSelection(
		_ selection: Set<SFTPTaskEntry.ID>,
		for side: SFTPTaskSide
	) {
		updateState(for: side) { $0.selection = selection }
	}

	func setShowsHiddenFiles(
		_ showsHiddenFiles: Bool,
		for side: SFTPTaskSide
	) {
		updateState(for: side) {
			$0.showsHiddenFiles = showsHiddenFiles
		}
	}

	func selectRemote(
		hostID: UUID,
		for side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		updateState(for: side) {
			$0.setEndpoint(.remote(hostID: hostID))
		}
		await refresh(side, hosts: hosts, transferStore: transferStore)
	}

	func selectLocal(
		locationID: UUID,
		for side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		updateState(for: side) {
			$0.setEndpoint(.local(locationID: locationID))
		}
		await refresh(side, hosts: hosts, transferStore: transferStore)
	}

	func authorizeLocal(
		url: URL,
		replacing locationID: UUID?,
		for side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		do {
			let location: LocalFileLocation
			if let locationID {
				location = try await locationStore.reauthorize(
					locationID,
					with: url
				)
			} else {
				location = try await locationStore.add(url: url)
			}
			await reloadLocations()
			await selectLocal(
				locationID: location.id,
				for: side,
				hosts: hosts,
				transferStore: transferStore
			)
		} catch {
			setError(error.localizedDescription, for: side)
		}
	}

	func navigate(
		_ side: SFTPTaskSide,
		to path: String,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		updateState(for: side) { $0.navigate(to: path) }
		await refresh(side, hosts: hosts, transferStore: transferStore)
	}

	func open(
		_ entry: SFTPTaskEntry,
		in side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		guard entry.isDirectory else { return }
		let pane = state(for: side)
		let child = joinedPath(
			pane.path,
			entry.name,
			endpoint: pane.endpoint
		)
		await navigate(
			side,
			to: child,
			hosts: hosts,
			transferStore: transferStore
		)
	}

	func goBack(
		_ side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		var moved = false
		updateState(for: side) { moved = $0.goBack() }
		guard moved else { return }
		await refresh(side, hosts: hosts, transferStore: transferStore)
	}

	func goForward(
		_ side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		var moved = false
		updateState(for: side) { moved = $0.goForward() }
		guard moved else { return }
		await refresh(side, hosts: hosts, transferStore: transferStore)
	}

	func goUp(
		_ side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		let pane = state(for: side)
		let parent: String
		switch pane.endpoint {
		case .unconfigured:
			return
		case .local:
			guard !pane.path.isEmpty else { return }
			parent = (pane.path as NSString).deletingLastPathComponent
		case .remote:
			guard pane.path != "~", pane.path != "/" else { return }
			let candidate = (pane.path as NSString)
				.deletingLastPathComponent
			parent = candidate.isEmpty ? "~" : candidate
		}
		await navigate(
			side,
			to: parent,
			hosts: hosts,
			transferStore: transferStore
		)
	}

	func refresh(
		_ side: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async {
		let pane = state(for: side)
		let revision = nextRefreshRevision(for: side)
		setLoading(true, for: side)
		setError(nil, for: side)
		do {
			let entries: [SFTPTaskEntry]
			switch pane.endpoint {
			case .unconfigured:
				entries = []
			case .local(let locationID):
				entries = try await localEntries(
					locationID: locationID,
					relativePath: pane.path
				)
			case .remote(let hostID):
				guard let host = hosts.first(where: { $0.id == hostID }) else {
					throw RemoteFileError.staleOperation
				}
				entries = try await remoteEntries(
					client: transferStore.client(for: host),
					path: pane.path
				)
			}
			guard refreshRevisions[side] == revision,
				state(for: side).endpoint == pane.endpoint,
				state(for: side).path == pane.path else {
				return
			}
			setEntries(entries, for: side)
		} catch {
			guard refreshRevisions[side] == revision else { return }
			setEntries([], for: side)
			setError(error.localizedDescription, for: side)
		}
		guard refreshRevisions[side] == revision else { return }
		setLoading(false, for: side)
	}

	@discardableResult
	func copy(
		entryIDs: Set<SFTPTaskEntry.ID>? = nil,
		from sourceSide: SFTPTaskSide,
		hosts: [SSHHost],
		transferStore: FileTransferStore
	) async -> [TaskId] {
		let destinationSide = sourceSide.opposite
		let source = state(for: sourceSide)
		let destination = state(for: destinationSide)
		guard let route = SFTPTaskTransferRoute.resolve(
			source: source.endpoint,
			destination: destination.endpoint
		) else {
			transferNotice = "Choose a local and remote pair, or two remote Hosts."
			return []
		}
		let selectedIDs = entryIDs ?? source.selection
		let selected = entries(for: sourceSide).filter {
			selectedIDs.contains($0.id)
		}
		guard !selected.isEmpty else {
			transferNotice = "Select at least one item to copy."
			return []
		}
		do {
			let ids: [TaskId]
			switch route {
			case .upload:
				guard case .local(let locationID) = source.endpoint,
					case .remote(let hostID) = destination.endpoint,
					let host = hosts.first(where: { $0.id == hostID }) else {
					throw RemoteFileError.staleOperation
				}
				let rootGrant = try await locationStore.access(locationID)
				let grants = try selected.map {
					try rootGrant.descendant(
						relativePath: joinedRelativePath(
							source.path,
							$0.name
						)
					)
				}
				ids = transferStore.enqueueScopedUpload(
					localFiles: grants,
					remoteDirectory: destination.path,
					host: host
				)
			case .download:
				guard case .remote(let hostID) = source.endpoint,
					case .local(let locationID) = destination.endpoint,
					let host = hosts.first(where: { $0.id == hostID }) else {
					throw RemoteFileError.staleOperation
				}
				let rootGrant = try await locationStore.access(locationID)
				let directoryGrant = try rootGrant.descendant(
					relativePath: destination.path
				)
				let remotePaths = selected.map {
					joinedPath(
						source.path,
						$0.name,
						endpoint: source.endpoint
					)
				}
				ids = transferStore.enqueueScopedDownload(
					remotePaths: remotePaths,
					localDirectory: directoryGrant,
					host: host,
					directoryPaths: Set(
						zip(remotePaths, selected).compactMap {
							path,
							entry in
							entry.isDirectory ? path : nil
						}
					)
				)
			case .remoteCopyViaMac:
				guard case .remote(let sourceHostID) = source.endpoint,
					case .remote(let destinationHostID) =
						destination.endpoint,
					let sourceHost = hosts.first(where: {
						$0.id == sourceHostID
					}),
					let destinationHost = hosts.first(where: {
						$0.id == destinationHostID
					}) else {
					throw RemoteFileError.staleOperation
				}
				ids = transferStore.enqueueRemoteCopy(
					remotePaths: selected.map {
						joinedPath(
							source.path,
							$0.name,
							endpoint: source.endpoint
						)
					},
					destinationDirectory: destination.path,
					sourceHost: sourceHost,
					destinationHost: destinationHost
				)
			}
			if ids.isEmpty {
				transferNotice = "The transfer could not be queued because a Host is unavailable."
			} else if route == .remoteCopyViaMac {
				transferNotice =
					"Relaying \(ids.count) item\(ids.count == 1 ? "" : "s") through this Mac."
			} else {
				transferNotice =
					"Queued \(ids.count) item\(ids.count == 1 ? "" : "s")."
			}
			return ids
		} catch {
			transferNotice = error.localizedDescription
			return []
		}
	}

	func dismissTransferNotice() {
		transferNotice = nil
	}

	private func localEntries(
		locationID: UUID,
		relativePath: String
	) async throws -> [SFTPTaskEntry] {
		let rootGrant = try await locationStore.access(locationID)
		let directoryGrant = try rootGrant.descendant(
			relativePath: relativePath
		)
		return try await directoryGrant.withAccess { url in
			try await Task.detached(priority: .userInitiated) {
				let keys: Set<URLResourceKey> = [
					.contentModificationDateKey,
					.fileSizeKey,
					.isDirectoryKey,
					.isRegularFileKey,
				]
				return try FileManager.default.contentsOfDirectory(
					at: url,
					includingPropertiesForKeys: Array(keys),
					options: []
				).map { child in
					let values = try child.resourceValues(forKeys: keys)
					let kind: SFTPTaskEntry.Kind
					if values.isDirectory == true {
						kind = .directory
					} else if values.isRegularFile == true {
						kind = .file
					} else {
						kind = .unknown
					}
					let attributes = try FileManager.default.attributesOfItem(
						atPath: child.path
					)
					let permissions = (
						attributes[.posixPermissions] as? NSNumber
					)?.uint16Value
					return SFTPTaskEntry(
						id: child.lastPathComponent,
						name: child.lastPathComponent,
						kind: kind,
						size: values.fileSize.map(Int64.init),
						modifiedAt: values.contentModificationDate,
						permissions: permissions
					)
				}.sorted {
					if $0.isDirectory != $1.isDirectory {
						return $0.isDirectory
					}
					return $0.name.localizedStandardCompare($1.name)
						== .orderedAscending
				}
			}.value
		}
	}

	private func remoteEntries(
		client: any RemoteFileClient,
		path: String
	) async throws -> [SFTPTaskEntry] {
		try await client.list(path).map {
			let kind: SFTPTaskEntry.Kind
			switch $0.type {
			case .file:
				kind = .file
			case .directory:
				kind = .directory
			case .unknown:
				kind = .unknown
			}
			return SFTPTaskEntry(
				id: $0.id,
				name: $0.name,
				kind: kind,
				size: $0.size,
				modifiedAt: $0.mtime,
				permissions: $0.mode
			)
		}.sorted {
			if $0.isDirectory != $1.isDirectory {
				return $0.isDirectory
			}
			return $0.name.localizedStandardCompare($1.name)
				== .orderedAscending
		}
	}

	private func reloadLocations() async {
		locations = await locationStore.locations
		if let loadError = await locationStore.loadError {
			transferNotice = loadError.localizedDescription
		}
	}

	private func nextRefreshRevision(
		for side: SFTPTaskSide
	) -> UInt64 {
		let revision = (refreshRevisions[side] ?? 0) &+ 1
		refreshRevisions[side] = revision
		return revision
	}

	private func updateState(
		for side: SFTPTaskSide,
		_ update: (inout SFTPTaskPaneState) -> Void
	) {
		if side == .left {
			update(&left)
		} else {
			update(&right)
		}
	}

	private func setEntries(
		_ entries: [SFTPTaskEntry],
		for side: SFTPTaskSide
	) {
		if side == .left {
			leftEntries = entries
		} else {
			rightEntries = entries
		}
	}

	private func setError(
		_ error: String?,
		for side: SFTPTaskSide
	) {
		if side == .left {
			leftError = error
		} else {
			rightError = error
		}
	}

	private func setLoading(
		_ isLoading: Bool,
		for side: SFTPTaskSide
	) {
		if side == .left {
			leftIsLoading = isLoading
		} else {
			rightIsLoading = isLoading
		}
	}

	private func joinedRelativePath(
		_ parent: String,
		_ child: String
	) -> String {
		parent.isEmpty ? child : (parent as NSString)
			.appendingPathComponent(child)
	}

	private func joinedPath(
		_ parent: String,
		_ child: String,
		endpoint: SFTPTaskEndpoint
	) -> String {
		switch endpoint {
		case .local:
			joinedRelativePath(parent, child)
		case .remote:
			(parent as NSString).appendingPathComponent(child)
		case .unconfigured:
			child
		}
	}
}
