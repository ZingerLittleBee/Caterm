import AppKit
import Foundation
import WorkspaceCore

enum WorkspaceCommand: Hashable, Sendable {
	case splitRight
	case splitDown
	case focusLeft
	case focusRight
	case focusUp
	case focusDown
	case focusPrevious
	case focusNext
	case toggleFocusMode
	case closePane

	func applying(to workspace: Workspace) throws -> WorkspaceCommandOutcome {
		switch self {
		case .splitRight:
			.update(try workspace.splittingActivePane(.right))
		case .splitDown:
			.update(try workspace.splittingActivePane(.down))
		case .focusLeft:
			.update(workspace.focusing(.left))
		case .focusRight:
			.update(workspace.focusing(.right))
		case .focusUp:
			.update(workspace.focusing(.up))
		case .focusDown:
			.update(workspace.focusing(.down))
		case .focusPrevious:
			.update(workspace.cyclingFocus(.previous))
		case .focusNext:
			.update(workspace.cyclingFocus(.next))
		case .toggleFocusMode:
			.update(workspace.togglingPresentation())
		case .closePane:
			.close(workspace.closingActivePane())
		}
	}
}

enum WorkspaceCommandOutcome: Equatable {
	case update(Workspace)
	case close(WorkspacePaneCloseResult)
}

extension Notification.Name {
	static let catermWorkspaceCommand = Notification.Name("catermWorkspaceCommand")
}

enum WorkspaceCommandNotificationKey {
	static let command = "command"
}

@MainActor
enum WorkspaceCommandDispatcher {
	static func post(_ command: WorkspaceCommand) {
		NotificationCenter.default.post(
			name: .catermWorkspaceCommand,
			object: WindowCommandScope.activeTargetWindow,
			userInfo: [WorkspaceCommandNotificationKey.command: command]
		)
	}
}
