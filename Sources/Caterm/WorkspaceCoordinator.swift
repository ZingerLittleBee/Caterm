import Combine
import Foundation
import HostAutomationRuntime
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
	private let resolveAutomation: (SSHHost) -> HostAutomationResolution
	private var runtime = WorkspaceRuntimeMap()

	init(
		sessionStore: SessionStore,
		resolveAutomation: @escaping (SSHHost) -> HostAutomationResolution = {
			_ in .disabled
		}
	) {
		self.sessionStore = sessionStore
		self.resolveAutomation = resolveAutomation
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
		try ensureSessions(for: workspace, installTerminfo: installTerminfo)
		return sessionID(for: workspace)
	}

	func ensureSessions(
		for workspace: Workspace,
		installTerminfo: Bool
	) throws {
		for pane in workspace.topology.panes {
			guard sessionID(for: pane.id, in: workspace) == nil else { continue }
			if runtime.sessionID(for: pane.id, in: workspace.id) != nil {
				runtime.unbind(paneID: pane.id, in: workspace.id)
				runtimeRevision &+= 1
			}
			guard let hostReference = pane.host,
			      let resolved = resolve(hostReference) else {
				continue
			}
			_ = try openSession(
				for: workspace,
				paneID: pane.id,
				host: resolved.host,
				installTerminfo: installTerminfo,
				authenticationMode: resolved.authenticationMode
			)
		}
	}

	func connectSavedHost(
		_ host: SSHHost,
		to paneID: PaneID,
		in workspace: Workspace,
		installTerminfo: Bool
	) throws -> Workspace {
		let updated = try workspace.assigningHost(.saved(id: host.id), to: paneID)
		_ = try openSession(
			for: updated,
			paneID: paneID,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: .configuredCredential
		)
		return updated
	}

	func connectOneTimeHost(
		_ host: SSHHost,
		to paneID: PaneID,
		in workspace: Workspace,
		installTerminfo: Bool
	) throws -> Workspace {
		let descriptor = try OneTimeConnectionDescriptor(
			displayName: host.name,
			hostname: host.hostname,
			port: host.port,
			username: host.username
		)
		let updated = try workspace.assigningHost(.oneTime(descriptor), to: paneID)
		_ = try openSession(
			for: updated,
			paneID: paneID,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: .interactive
		)
		return updated
	}

	func replaceSavedHost(
		_ host: SSHHost,
		in paneID: PaneID,
		workspace: Workspace,
		installTerminfo: Bool
	) throws -> Workspace {
		let updated = try workspace.replacingHost(.saved(id: host.id), in: paneID)
		closePane(paneID, in: workspace.id)
		_ = try openSession(
			for: updated,
			paneID: paneID,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: .configuredCredential
		)
		return updated
	}

	func sessionID(for paneID: PaneID, in workspace: Workspace) -> UUID? {
		guard let sessionID = runtime.sessionID(for: paneID, in: workspace.id) else {
			return nil
		}
		return sessionStore.tabs.contains(where: { $0.id == sessionID })
			? sessionID
			: nil
	}

	func closePane(_ paneID: PaneID, in workspaceID: WorkspaceID) {
		guard let sessionID = runtime.unbind(paneID: paneID, in: workspaceID) else {
			return
		}
		sessionStore.closeTab(tabId: sessionID)
		runtimeRevision &+= 1
	}

	private func resolve(
		_ hostReference: WorkspaceHostReference
	) -> (host: SSHHost, authenticationMode: SSHAuthenticationMode)? {
		let host: SSHHost
		let authenticationMode: SSHAuthenticationMode
		switch hostReference {
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
		return (host, authenticationMode)
	}

	func sessionID(for workspace: Workspace) -> UUID? {
		sessionID(for: workspace.activePaneID, in: workspace)
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
			paneID: workspace.activePaneID,
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: authenticationMode
		)
		return workspace
	}

	private func openSession(
		for workspace: Workspace,
		paneID: PaneID,
		host: SSHHost,
		installTerminfo: Bool,
		authenticationMode: SSHAuthenticationMode
	) throws -> UUID {
		let sessionID = sessionStore.openTab(
			host: host,
			installTerminfo: installTerminfo,
			authenticationMode: authenticationMode,
			automationResolution: resolveAutomation(host)
		)
		do {
			try runtime.bind(
				sessionID: sessionID,
				to: paneID,
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
