import Foundation
import SessionStore
import WorkspaceCore

struct ActivePaneFileTarget: Equatable, Hashable, Sendable {
	let paneID: PaneID
	let sessionID: UUID
	let hostID: UUID
}

enum ActivePaneFileUnavailable: Equatable, Hashable, Sendable {
	case chooseHost
	case missingHost
	case oneTimeConnection
	case connecting
	case reconnecting
	case disconnected
	case staleSession

	var title: String {
		switch self {
		case .chooseHost: "Choose a Host"
		case .missingHost: "Host Unavailable"
		case .oneTimeConnection: "Files Unavailable"
		case .connecting: "Connecting"
		case .reconnecting: "Reconnecting"
		case .disconnected: "Not Connected"
		case .staleSession: "Session Changed"
		}
	}

	var message: String {
		switch self {
		case .chooseHost:
			"Choose a Host for the active Pane before browsing files."
		case .missingHost:
			"The saved Host for the active Pane no longer exists."
		case .oneTimeConnection:
			"The file tool is available only for saved Hosts."
		case .connecting:
			"Wait for the active Pane to finish connecting."
		case .reconnecting:
			"Files will be available after the active Pane reconnects."
		case .disconnected:
			"Retry the active Pane before browsing files."
		case .staleSession:
			"The active Pane session changed. Reopen the file tool target."
		}
	}
}

enum ActivePaneFileContext: Equatable, Hashable, Sendable {
	case ready(ActivePaneFileTarget)
	case unavailable(ActivePaneFileUnavailable)
}

enum ActivePaneFileContextResolver {
	static func resolve(
		workspace: Workspace,
		sessionID: UUID?,
		tab: SessionStore.Tab?,
		savedHostExists: Bool
	) -> ActivePaneFileContext {
		guard let pane = workspace.topology.pane(id: workspace.activePaneID) else {
			return .unavailable(.staleSession)
		}
		guard let hostReference = pane.host else {
			return .unavailable(.chooseHost)
		}
		guard case .saved(let savedHostID) = hostReference else {
			return .unavailable(.oneTimeConnection)
		}
		guard savedHostExists else {
			return .unavailable(.missingHost)
		}
		guard let sessionID, let tab else {
			return .unavailable(.disconnected)
		}
		guard tab.id == sessionID, tab.host.id == savedHostID else {
			return .unavailable(.staleSession)
		}
		switch tab.state {
		case .connected:
			return .ready(ActivePaneFileTarget(
				paneID: pane.id,
				sessionID: sessionID,
				hostID: savedHostID
			))
		case .idle, .preflight, .authenticating:
			return .unavailable(.connecting)
		case .reconnecting:
			return .unavailable(.reconnecting)
		case .failed:
			return .unavailable(.disconnected)
		}
	}
}
