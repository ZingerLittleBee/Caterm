import Foundation

enum SFTPTaskEndpoint: Codable, Equatable, Hashable, Sendable {
	case unconfigured
	case local(locationID: UUID)
	case remote(hostID: UUID)

	var defaultPath: String {
		switch self {
		case .unconfigured, .local:
			""
		case .remote:
			"~"
		}
	}
}

enum SFTPTaskTransferRoute: Equatable, Sendable {
	case upload
	case download
	case remoteCopyViaMac

	static func resolve(
		source: SFTPTaskEndpoint,
		destination: SFTPTaskEndpoint
	) -> SFTPTaskTransferRoute? {
		switch (source, destination) {
		case (.local, .remote):
			.upload
		case (.remote, .local):
			.download
		case (.remote, .remote):
			.remoteCopyViaMac
		case (.unconfigured, _), (_, .unconfigured), (.local, .local):
			nil
		}
	}
}

struct SFTPTaskEntry: Equatable, Hashable, Identifiable, Sendable {
	enum Kind: String, Equatable, Hashable, Sendable {
		case file
		case directory
		case unknown
	}

	let id: String
	let name: String
	let kind: Kind
	let size: Int64?
	let modifiedAt: Date?
	let permissions: UInt16?

	init(
		id: String? = nil,
		name: String,
		kind: Kind,
		size: Int64?,
		modifiedAt: Date?,
		permissions: UInt16?
	) {
		self.id = id ?? name
		self.name = name
		self.kind = kind
		self.size = size
		self.modifiedAt = modifiedAt
		self.permissions = permissions
	}

	var isDirectory: Bool {
		kind == .directory
	}

	var isHidden: Bool {
		name.hasPrefix(".")
	}
}

struct SFTPTaskPaneState: Equatable, Sendable {
	var endpoint: SFTPTaskEndpoint
	private(set) var path: String
	private(set) var backHistory: [String]
	private(set) var forwardHistory: [String]
	var showsHiddenFiles: Bool
	var selection: Set<SFTPTaskEntry.ID>

	init(
		endpoint: SFTPTaskEndpoint = .unconfigured,
		path: String? = nil,
		backHistory: [String] = [],
		forwardHistory: [String] = [],
		showsHiddenFiles: Bool = false,
		selection: Set<SFTPTaskEntry.ID> = []
	) {
		self.endpoint = endpoint
		self.path = path ?? endpoint.defaultPath
		self.backHistory = backHistory
		self.forwardHistory = forwardHistory
		self.showsHiddenFiles = showsHiddenFiles
		self.selection = selection
	}

	var canGoBack: Bool {
		!backHistory.isEmpty
	}

	var canGoForward: Bool {
		!forwardHistory.isEmpty
	}

	mutating func setEndpoint(_ endpoint: SFTPTaskEndpoint) {
		self.endpoint = endpoint
		path = endpoint.defaultPath
		backHistory = []
		forwardHistory = []
		selection = []
	}

	mutating func navigate(to path: String) {
		guard path != self.path else { return }
		backHistory.append(self.path)
		self.path = path
		forwardHistory = []
		selection = []
	}

	@discardableResult
	mutating func goBack() -> Bool {
		guard let previous = backHistory.popLast() else { return false }
		forwardHistory.append(path)
		path = previous
		selection = []
		return true
	}

	@discardableResult
	mutating func goForward() -> Bool {
		guard let next = forwardHistory.popLast() else { return false }
		backHistory.append(path)
		path = next
		selection = []
		return true
	}

	func visibleEntries(
		in entries: [SFTPTaskEntry]
	) -> [SFTPTaskEntry] {
		guard !showsHiddenFiles else { return entries }
		return entries.filter { !$0.isHidden }
	}
}
