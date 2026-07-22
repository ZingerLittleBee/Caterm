import Combine
import Foundation
import SessionStore
import SSHCommandBuilder
import WorkspaceCore

@MainActor
final class WorkspaceCoordinator: ObservableObject {
	enum Error: Swift.Error, Equatable, LocalizedError {
		case runtimeBinding(WorkspaceRuntimeMap.Error)

		var errorDescription: String? {
			"The Workspace could not attach its terminal session."
		}
	}

	@Published private(set) var runtimeRevision: UInt64 = 0

	private let sessionStore: SessionStore
	private var runtime = WorkspaceRuntimeMap()

	init(sessionStore: SessionStore) {
		self.sessionStore = sessionStore
	}

	func openSavedHost(
		_ host: SSHHost,
		installTerminfo: Bool
	) throws -> Workspace {
		try openWorkspace(
			host: host,
			reference: .saved(id: host.id),
			installTerminfo: installTerminfo,
			authenticationMode: .configuredCredential
		)
	}

	func openOneTimeHost(
		_ host: SSHHost,
		installTerminfo: Bool
	) throws -> Workspace {
		let descriptor = try OneTimeConnectionDescriptor(
			displayName: host.name,
			hostname: host.hostname,
			port: host.port,
			username: host.username
		)
		return try openWorkspace(
			host: host,
			reference: .oneTime(descriptor),
			installTerminfo: installTerminfo,
			authenticationMode: .interactive
		)
	}

	func ensureSession(
		for workspace: Workspace,
		installTerminfo: Bool
	) throws -> UUID? {
		if let existing = sessionID(for: workspace) {
			return existing
		}

		if runtime.sessionID(for: workspace.activePaneID, in: workspace.id) != nil {
			runtime.unbind(paneID: workspace.activePaneID, in: workspace.id)
			runtimeRevision &+= 1
		}

		guard let pane = workspace.topology.panes.first else { return nil }
		let host: SSHHost
		let authenticationMode: SSHAuthenticationMode
		switch pane.host {
		case .saved(let hostID):
			guard let savedHost = sessionStore.hosts.first(where: { $0.id == hostID }) else {
				return nil
			}
			host = savedHost
			authenticationMode = .configuredCredential
		case .oneTime(let descriptor):
			host = SSHHost(
				name: descriptor.displayName,
				hostname: descriptor.hostname,
				port: descriptor.port,
				username: descriptor.username,
				credential: .agent
			)
			authenticationMode = .interactive
		}

		return try openSession(
			for: workspace,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: authenticationMode
		)
	}

	func sessionID(for workspace: Workspace) -> UUID? {
		guard let sessionID = runtime.sessionID(
			for: workspace.activePaneID,
			in: workspace.id
		) else {
			return nil
		}
		return sessionStore.tabs.contains(where: { $0.id == sessionID })
			? sessionID
			: nil
	}

	func closeWorkspace(_ workspaceID: WorkspaceID) {
		let sessionIDs = runtime.unbind(workspaceID: workspaceID)
		guard !sessionIDs.isEmpty else { return }
		for sessionID in sessionIDs {
			sessionStore.closeTab(tabId: sessionID)
		}
		runtimeRevision &+= 1
	}

	private func openWorkspace(
		host: SSHHost,
		reference: WorkspaceHostReference,
		installTerminfo: Bool,
		authenticationMode: SSHAuthenticationMode
	) throws -> Workspace {
		let workspace = Workspace.onePane(host: reference)
		_ = try openSession(
			for: workspace,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: authenticationMode
		)
		return workspace
	}

	private func openSession(
		for workspace: Workspace,
		host: SSHHost,
		installTerminfo: Bool,
		authenticationMode: SSHAuthenticationMode
	) throws -> UUID {
		let sessionID = sessionStore.openTab(
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: authenticationMode
		)
		do {
			try runtime.bind(
				sessionID: sessionID,
				to: workspace.activePaneID,
				in: workspace
			)
		} catch let error as WorkspaceRuntimeMap.Error {
			sessionStore.closeTab(tabId: sessionID)
			throw Error.runtimeBinding(error)
		}
		runtimeRevision &+= 1
		return sessionID
	}
}
