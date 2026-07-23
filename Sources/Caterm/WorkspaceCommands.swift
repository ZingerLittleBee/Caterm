import AppKit
import Foundation
import SwiftUI
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

struct WorkspaceCommandHandler {
	let perform: @MainActor (WorkspaceCommand) -> Void

	@MainActor
	func callAsFunction(_ command: WorkspaceCommand) {
		perform(command)
	}
}

private struct WorkspaceCommandHandlerKey: FocusedValueKey {
	typealias Value = WorkspaceCommandHandler
}

extension FocusedValues {
	var workspaceCommandHandler: WorkspaceCommandHandler? {
		get { self[WorkspaceCommandHandlerKey.self] }
		set { self[WorkspaceCommandHandlerKey.self] = newValue }
	}
}

@MainActor
struct WorkspacePaneCommands: Commands {
	@FocusedValue(\.workspaceCommandHandler)
	private var handler

	var body: some Commands {
		CommandMenu("Pane") {
			Button("Split Right") {
				handler?(.splitRight)
			}
			.keyboardShortcut("d", modifiers: .command)
			.disabled(handler == nil)

			Button("Split Down") {
				handler?(.splitDown)
			}
			.keyboardShortcut("d", modifiers: [.command, .shift])
			.disabled(handler == nil)

			Divider()

			Button("Focus Left Pane") {
				handler?(.focusLeft)
			}
			.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
			.disabled(handler == nil)

			Button("Focus Right Pane") {
				handler?(.focusRight)
			}
			.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
			.disabled(handler == nil)

			Button("Focus Pane Above") {
				handler?(.focusUp)
			}
			.keyboardShortcut(.upArrow, modifiers: [.command, .option])
			.disabled(handler == nil)

			Button("Focus Pane Below") {
				handler?(.focusDown)
			}
			.keyboardShortcut(.downArrow, modifiers: [.command, .option])
			.disabled(handler == nil)

			Button("Focus Previous Pane") {
				handler?(.focusPrevious)
			}
			.keyboardShortcut("[", modifiers: [.command, .option])
			.disabled(handler == nil)

			Button("Focus Next Pane") {
				handler?(.focusNext)
			}
			.keyboardShortcut("]", modifiers: [.command, .option])
			.disabled(handler == nil)

			Divider()

			Button("Toggle Focus Mode") {
				handler?(.toggleFocusMode)
			}
			.keyboardShortcut(.return, modifiers: [.command, .shift])
			.disabled(handler == nil)

			Button("Close Pane") {
				handler?(.closePane)
			}
			.keyboardShortcut("w", modifiers: [.command, .option])
			.disabled(handler == nil)
		}
	}
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
