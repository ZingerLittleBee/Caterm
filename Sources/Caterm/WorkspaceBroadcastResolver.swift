import Foundation
import SessionStore
import TerminalEngine
import WorkspaceBroadcast
import WorkspaceCore

@MainActor
enum WorkspaceBroadcastResolver {
	static func candidates(
		in workspace: Workspace,
		coordinator: WorkspaceCoordinator,
		store: SessionStore,
		registry: SurfaceRegistry
	) -> [WorkspaceBroadcastRecipient] {
		_ = registry.revision
		return workspace.topology.panes.enumerated().compactMap { index, pane in
			guard let sessionID = coordinator.sessionID(for: pane.id, in: workspace),
			      let tab = store.tabs.first(where: { $0.id == sessionID }),
			      WorkspaceBroadcastConnectionPolicy.isEligible(
					state: tab.state,
					hadConfirmedConnection: tab.hadConnected
				  ),
			      let leaseID = registry.leaseID(for: sessionID) else {
				return nil
			}
			return WorkspaceBroadcastRecipient(
				workspaceID: workspace.id,
				paneID: pane.id,
				sessionID: sessionID,
				surfaceLeaseID: leaseID,
				paneLabel: "Pane \(index + 1)",
				hostName: tab.host.name,
				address: "\(tab.host.username)@\(tab.host.hostname):\(tab.host.port)"
			)
		}
	}

	static func eligibility(
		of recipient: WorkspaceBroadcastRecipient,
		in workspace: Workspace,
		coordinator: WorkspaceCoordinator,
		store: SessionStore,
		registry: SurfaceRegistry
	) -> WorkspaceBroadcastEligibility {
		guard recipient.workspaceID == workspace.id,
		      workspace.topology.pane(id: recipient.paneID) != nil,
		      coordinator.sessionID(for: recipient.paneID, in: workspace)
			== recipient.sessionID,
		      let tab = store.tabs.first(where: { $0.id == recipient.sessionID }) else {
			return .missing
		}
		guard WorkspaceBroadcastConnectionPolicy.isEligible(
			state: tab.state,
			hadConfirmedConnection: tab.hadConnected
		) else { return .disconnected }
		guard let currentLeaseID = registry.leaseID(for: recipient.sessionID) else {
			return .missing
		}
		guard currentLeaseID == recipient.surfaceLeaseID else {
			return .surfaceReplaced
		}
		return .eligible
	}

	static func send(
		_ text: String,
		to recipient: WorkspaceBroadcastRecipient,
		registry: SurfaceRegistry
	) throws {
		guard let surface = registry.surface(
			for: recipient.sessionID,
			leaseID: recipient.surfaceLeaseID
		) else {
			throw WorkspaceBroadcastDeliveryError.surfaceUnavailable
		}
		surface.run(text)
	}
}

enum WorkspaceBroadcastDeliveryError: Error, Equatable, LocalizedError {
	case surfaceUnavailable

	var errorDescription: String? {
		"The armed terminal surface is no longer available."
	}
}

enum WorkspaceBroadcastConnectionPolicy {
	static func isEligible(
		state: ConnectionState,
		hadConfirmedConnection: Bool
	) -> Bool {
		guard hadConfirmedConnection, case .connected = state else { return false }
		return true
	}
}
