import AppKit
import Darwin
import FileTransferStore
import KeychainStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import TerminalEngine
import WorkspaceBroadcast
import WorkspaceCore
import WorkspaceTemplateStore
import XCTest
@testable import Caterm

@MainActor
final class WorkspaceGhosttySurfaceAcceptanceTests: XCTestCase {
	func testTwoAndFourProductionGhosttySurfacesCompleteCommonWorkspaceWorkflow() async throws {
		guard await LocalSSHAvailability.probe() else {
			throw XCTSkip("Local SSH is unavailable on this host.")
		}
		_ = NSApplication.shared
		for surfaceCount in [2, 4] {
			let fixture = try GhosttyWorkspaceFixture(surfaceCount: surfaceCount)
			addTeardownBlock { @MainActor in
				await fixture.cleanUp()
			}
			try await fixture.prepareSessions()
			try await fixture.attachWindow()
			try await fixture.waitForAllSurfaces()

			let originalSurfaceIDs = try fixture.surfaceObjectIdentifiers()
			try fixture.resizeWindowThroughSupportedRange()
			XCTAssertEqual(try fixture.surfaceObjectIdentifiers(), originalSurfaceIDs)
			try fixture.focusEverySurface()
			try await fixture.saveReloadAndInstantiateTemplate()

			let originalShellPIDs = try await fixture.sendUniqueInputAndReadShellPIDs()
			XCTAssertEqual(Set(originalShellPIDs).count, surfaceCount)
			try await fixture.broadcastAndVerify(shellPIDs: originalShellPIDs)

			let reconnectedPID = try await fixture.reconnectLastSurface()
			XCTAssertNotEqual(reconnectedPID, originalShellPIDs.last)
			try await fixture.closeWorkspaceAndWaitForTeardown()
			XCTAssertTrue(fixture.store.tabs.isEmpty)
			XCTAssertTrue(fixture.registry.activeTabIds().isEmpty)
			await fixture.cleanUp()
		}
	}

	func testEightProductionGhosttySurfacesResizeFocusBroadcastReconnectAndTearDown() async throws {
		guard await LocalSSHAvailability.probe() else {
			throw XCTSkip("Local SSH is unavailable on this host.")
		}
		_ = NSApplication.shared
		let fixture = try GhosttyWorkspaceFixture(surfaceCount: 8)
		addTeardownBlock { @MainActor in
			await fixture.cleanUp()
		}
		try await fixture.prepareSessions()

		try await fixture.attachWindow()
		try await fixture.waitForAllSurfaces()

		let originalSurfaceIDs = try fixture.surfaceObjectIdentifiers()
		try fixture.resizeWindowThroughSupportedRange()
		XCTAssertEqual(try fixture.surfaceObjectIdentifiers(), originalSurfaceIDs)
		try fixture.focusEverySurface()

		let originalShellPIDs = try await fixture.sendUniqueInputAndReadShellPIDs()
		XCTAssertEqual(Set(originalShellPIDs).count, 8)
		let processID = getpid()
		let firstSample = try await Task.detached {
			try ProcessResourceSnapshot.capture(
				rootProcessID: processID,
				additionalProcessIDs: Set(originalShellPIDs)
			)
		}.value
		try await Task.sleep(for: .seconds(2))
		let secondSample = try await Task.detached {
			try ProcessResourceSnapshot.capture(
				rootProcessID: processID,
				additionalProcessIDs: Set(originalShellPIDs)
			)
		}.value
		let peakResidentBytes = max(firstSample.residentBytes, secondSample.residentBytes)
		let cpuDelta = secondSample.cpuSeconds - firstSample.cpuSeconds
		print(
			"Eight-surface resource evidence: processes=\(secondSample.processIDs.count), "
				+ "peak_rss_bytes=\(peakResidentBytes), cpu_delta_seconds=\(cpuDelta)"
		)
		XCTAssertTrue(secondSample.processIDs.isSuperset(of: originalShellPIDs))
		XCTAssertGreaterThanOrEqual(
			secondSample.processIDs.count,
			17,
			"The sample must include the test process, eight SSH clients, and eight remote shells"
		)
		XCTAssertLessThanOrEqual(
			peakResidentBytes,
			1_610_612_736,
			"Eight live surfaces and their local SSH process graph must stay below 1.5 GiB RSS"
		)
		XCTAssertGreaterThanOrEqual(cpuDelta, 0)
		XCTAssertLessThanOrEqual(
			cpuDelta,
			4,
			"Eight idle surfaces must consume no more than four CPU-seconds in a two-second window"
		)
		try await fixture.broadcastAndVerify(shellPIDs: originalShellPIDs)

		let reconnectedPID = try await fixture.reconnectLastSurface()
		XCTAssertNotEqual(reconnectedPID, originalShellPIDs.last)

		try await fixture.closeWorkspaceAndWaitForTeardown()
		XCTAssertTrue(fixture.store.tabs.isEmpty)
		XCTAssertTrue(fixture.registry.activeTabIds().isEmpty)
		fixture.coordinator.closeWorkspace(fixture.workspace.id)
		XCTAssertTrue(fixture.store.tabs.isEmpty)
	}
}

@MainActor
private final class GhosttyWorkspaceFixture {
	let store: SessionStore
	let registry = SurfaceRegistry()
	let coordinator: WorkspaceCoordinator
	private let rootURL: URL
	private let knownHostsURL: URL
	private let surfaceCount: Int
	private var treeCoordinator: NativeWorkspaceTreeView.Coordinator? = .init { _, _ in }
	private let container = WorkspaceTreeContainerView(
		frame: CGRect(x: 0, y: 0, width: 1_000, height: 650)
	)
	private let window: NSWindow
	private(set) var workspace: Workspace
	private var surfaceGenerations: [UUID: Int] = [:]

	init(surfaceCount: Int) throws {
		self.surfaceCount = surfaceCount
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-ghostty-acceptance-\(UUID())", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		knownHostsURL = rootURL.appendingPathComponent("known_hosts")
		let userKnownHosts = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath
		store = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: knownHostsURL.path,
			knownHostsUser: userKnownHosts,
			accessGroup: nil,
			hostsURL: rootURL.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.ghostty-acceptance.\(UUID())",
				accessGroup: nil
			),
			controlMasterManager: ControlMasterManager.shared,
			preflight: AvailableLocalPreflight()
		)
		coordinator = WorkspaceCoordinator(sessionStore: store)
		let hosts = (0..<surfaceCount).map { index in
			SSHHost(
				name: "Local Acceptance \(index + 1)",
				hostname: "localhost",
				port: 22,
				username: NSUserName(),
				credential: .agent
			)
		}
		for host in hosts { try store.addHost(host) }
		guard let firstHost = hosts.first else {
			throw GhosttyAcceptanceError.missingSurface
		}
		var workspace = try coordinator.openSavedHost(firstHost, installTerminfo: false)
		let workspaceCoordinator = coordinator
		let originalPaneID = workspace.activePaneID
		func addPane(from paneID: PaneID, direction: WorkspaceSplitPlacement, hostIndex: Int) throws -> PaneID {
			workspace = try workspace.activatingPane(paneID)
			workspace = try workspace.splittingActivePane(direction)
			workspace = try workspaceCoordinator.connectSavedHost(
				hosts[hostIndex],
				to: workspace.activePaneID,
				in: workspace,
				installTerminfo: false
			)
			return workspace.activePaneID
		}
		if surfaceCount > 1 {
			let rightPaneID = try addPane(from: originalPaneID, direction: .right, hostIndex: 1)
			if surfaceCount > 2 {
				_ = try addPane(from: originalPaneID, direction: .down, hostIndex: 2)
			}
			if surfaceCount > 3 {
				_ = try addPane(from: rightPaneID, direction: .down, hostIndex: 3)
			}
		}
		if surfaceCount > 4 {
			let firstFourPaneIDs = Array(workspace.topology.paneIDs.prefix(4))
			for (offset, paneID) in firstFourPaneIDs.enumerated()
				where offset + 4 < surfaceCount {
				_ = try addPane(from: paneID, direction: .right, hostIndex: offset + 4)
			}
		}
		self.workspace = workspace
		window = NSWindow(
			contentRect: container.frame,
			styleMask: [.titled, .resizable, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
	}

	func prepareSessions() async throws {
		for tabID in try sessionIDs() {
			await store.awaitConnectionAttempt(tabId: tabID)
			guard let tab = store.tabs.first(where: { $0.id == tabID }),
			      case .authenticating = tab.state else {
				throw GhosttyAcceptanceError.sessionDidNotAuthenticate
			}
			surfaceGenerations[tabID] = 0
		}
	}

	func attachWindow() async throws {
		window.contentView = container
		window.makeKeyAndOrderFront(nil)
		updateTree()
		container.layoutSubtreeIfNeeded()
		try await waitUntil(timeoutError: .attachmentTimedOut) {
			self.terminalViews.count == self.surfaceCount
		}
	}

	func waitForAllSurfaces() async throws {
		let ids = try sessionIDs()
		try await waitUntil(timeout: 12, timeoutError: .surfaceDiscoveryTimedOut) {
			ids.allSatisfy { self.registry.surface(for: $0) != nil }
		}
		try await Task.sleep(for: .seconds(4))
	}

	func surfaceObjectIdentifiers() throws -> Set<ObjectIdentifier> {
		let surfaces = try sessionIDs().compactMap { registry.surface(for: $0) }
		guard surfaces.count == surfaceCount else {
			throw GhosttyAcceptanceError.missingSurface
		}
		return Set(surfaces.map(ObjectIdentifier.init))
	}

	func resizeWindowThroughSupportedRange() throws {
		let originalViews = Set(terminalViews.map(ObjectIdentifier.init))
		for size in [
			CGSize(width: 1_800, height: 1_000),
			CGSize(width: 1_000, height: 650),
			CGSize(width: 1_440, height: 900),
		] {
			window.setContentSize(size)
			container.layoutSubtreeIfNeeded()
			let views = terminalViews
			XCTAssertEqual(views.count, surfaceCount)
			XCTAssertEqual(Set(views.map(ObjectIdentifier.init)), originalViews)
			XCTAssertTrue(views.allSatisfy {
				$0.frame.width.isFinite && $0.frame.height.isFinite
					&& $0.frame.width >= 0 && $0.frame.height >= 0
			})
		}
	}

	func focusEverySurface() throws {
		let views = terminalViews
		guard views.count == surfaceCount else {
			throw GhosttyAcceptanceError.missingSurface
		}
		for view in views {
			XCTAssertTrue(window.makeFirstResponder(view))
			XCTAssertTrue(window.firstResponder === view)
		}
	}

	func saveReloadAndInstantiateTemplate() async throws {
		let directory = rootURL.appendingPathComponent("templates", isDirectory: true)
		let templates = WorkspaceTemplateStore(directory: directory)
		let saved = try await templates.save(
			workspace: workspace,
			name: "Local (surfaceCount)-Pane Acceptance"
		)
		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()
		let persisted = try XCTUnwrap(reloaded.templates.first(where: { $0.id == saved.id }))
		let instantiated = try persisted.instantiate(
			availableHostIDs: Set(store.hosts.map(\.id))
		)
		XCTAssertNotEqual(instantiated.workspace.id, workspace.id)
		XCTAssertEqual(instantiated.workspace.topology.paneCount, surfaceCount)
		XCTAssertEqual(instantiated.workspace.presentation, workspace.presentation)
	}

	func sendUniqueInputAndReadShellPIDs() async throws -> [Int32] {
		let ids = try sessionIDs()
		let outputURLs = (0..<surfaceCount).map {
			rootURL.appendingPathComponent("pane-\($0).pid")
		}
		for (surface, url) in zip(ids.compactMap({ registry.surface(for: $0) }), outputURLs) {
			surface.setFocus(true)
			surface.run("printf '%s' \"$$\" > \(shellQuote(url.path))")
		}
		try await waitUntil(timeout: 8, timeoutError: .inputTimedOut) {
			outputURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
		}
		return try outputURLs.map { url in
			let body = try String(contentsOf: url, encoding: .utf8)
			guard let processID = Int32(body.trimmingCharacters(in: .whitespacesAndNewlines)) else {
				throw GhosttyAcceptanceError.invalidProcessID
			}
			return processID
		}
	}

	func broadcastAndVerify(shellPIDs: [Int32]) async throws {
		for tabID in try sessionIDs() {
			store.markConnected(tabId: tabID)
		}
		let recipients = WorkspaceBroadcastResolver.candidates(
			in: workspace,
			coordinator: coordinator,
			store: store,
			registry: registry
		)
		XCTAssertEqual(recipients.count, surfaceCount)
		let broadcastURL = rootURL.appendingPathComponent("broadcast.pids")
		let command = "printf '%s\\n' \"$$\" >> \(shellQuote(broadcastURL.path))"
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspace.id,
			source: .command(command),
			recipients: recipients
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		await session.deliver(
			eligibility: { recipient in
				WorkspaceBroadcastResolver.eligibility(
					of: recipient,
					in: self.workspace,
					coordinator: self.coordinator,
					store: self.store,
					registry: self.registry
				)
			},
			send: { recipient, text in
				try WorkspaceBroadcastResolver.send(text, to: recipient, registry: self.registry)
			}
		)
		XCTAssertTrue(session.latestReport?.outcomes.allSatisfy {
			$0.status == .delivered
		} == true)
		try await waitUntil(timeout: 8, timeoutError: .broadcastTimedOut) {
			guard let body = try? String(contentsOf: broadcastURL, encoding: .utf8) else {
				return false
			}
			return body.split(whereSeparator: \.isNewline).count == self.surfaceCount
		}
		let received = try String(contentsOf: broadcastURL, encoding: .utf8)
			.split(whereSeparator: \.isNewline)
			.map(String.init)
		XCTAssertEqual(Set(received), Set(shellPIDs.map(String.init)))
	}

	func reconnectLastSurface() async throws -> Int32 {
		let ids = try sessionIDs()
		let tabID = try XCTUnwrap(ids.last)
		let oldIdentity = ObjectIdentifier(try XCTUnwrap(registry.surface(for: tabID)))
		let oldSurface = WeakSurfaceReference(try XCTUnwrap(registry.surface(for: tabID)))
		store.retryTab(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)
		surfaceGenerations[tabID, default: 0] += 1
		updateTree()
		try await waitUntil(timeout: 12, timeoutError: .reconnectTimedOut) {
			guard let replacement = self.registry.surface(for: tabID) else { return false }
			return ObjectIdentifier(replacement) != oldIdentity
		}
		try await waitUntil(timeoutError: .reconnectTeardownTimedOut) {
			oldSurface.surface == nil
		}
		try await Task.sleep(for: .seconds(1))
		let outputURL = rootURL.appendingPathComponent("reconnected.pid")
		let replacement = try XCTUnwrap(registry.surface(for: tabID))
		replacement.run("printf '%s' \"$$\" > \(shellQuote(outputURL.path))")
		try await waitUntil(timeout: 8, timeoutError: .reconnectInputTimedOut) {
			FileManager.default.fileExists(atPath: outputURL.path)
		}
		let body = try String(contentsOf: outputURL, encoding: .utf8)
		guard let processID = Int32(body.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			throw GhosttyAcceptanceError.invalidProcessID
		}
		return processID
	}

	func closeWorkspaceAndWaitForTeardown() async throws {
		let ids = try sessionIDs()
		let retired = ids.compactMap { registry.surface(for: $0) }.map(WeakSurfaceReference.init)
		coordinator.closeWorkspace(workspace.id)
		container.install(NSView())
		treeCoordinator = nil
		try await waitUntil(timeout: 8, timeoutError: .teardownTimedOut) {
			self.store.tabs.isEmpty && retired.allSatisfy { $0.surface == nil }
		}
		for tabID in ids { registry.unregister(tabID) }
		await ControlMasterManager.shared.tearDownAll()
	}

	func cleanUp() async {
		coordinator.closeWorkspace(workspace.id)
		window.orderOut(nil)
		window.contentView = nil
		container.install(NSView())
		treeCoordinator = nil
		window.close()
		try? await Task.sleep(for: .milliseconds(100))
		await ControlMasterManager.shared.tearDownAll()
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func updateTree() {
		guard let treeCoordinator else { return }
		treeCoordinator.update(
			container,
			topology: workspace.topology,
			activePaneID: workspace.activePaneID,
			presentation: .split,
			paneContent: { pane in
				guard let tabID = self.coordinator.sessionID(for: pane.id, in: self.workspace) else {
					return AnyView(EmptyView())
				}
				guard let config = self.store.surfaceConfig(for: tabID) else {
					return AnyView(EmptyView())
				}
				return AnyView(
					AcceptanceTerminalRepresentable(
						tabId: tabID,
						command: config.command + " /bin/sh",
						env: config.env,
						isFocused: pane.id == self.workspace.activePaneID,
						registry: self.registry
					)
					.id("\(tabID)-\(self.surfaceGenerations[tabID, default: 0])")
				)
			},
			onRatioChange: { _, _ in }
		)
	}

	private func sessionIDs() throws -> [UUID] {
		try workspace.topology.panes.map { pane in
			try XCTUnwrap(coordinator.sessionID(for: pane.id, in: workspace))
		}
	}

	private var terminalViews: [GhosttySurfaceNSView] {
		container.productionDescendants.compactMap { $0 as? GhosttySurfaceNSView }
	}
}

@MainActor
private struct AcceptanceTerminalRepresentable: NSViewRepresentable {
	let tabId: UUID
	let command: String
	let env: [(String, String)]
	let isFocused: Bool
	let registry: SurfaceRegistry

	final class Coordinator {
		var registrationTask: Task<Void, Never>?

		deinit { registrationTask?.cancel() }
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> GhosttySurfaceNSView {
		let view = GhosttySurfaceNSView(command: command, env: env)
		view.setPaneFocusRequested(isFocused)
		context.coordinator.registrationTask = Task { @MainActor [weak view, weak registry] in
			for _ in 0..<120 {
				guard !Task.isCancelled else { return }
				if let surface = view?.surface {
					registry?.register(surface, for: tabId)
					return
				}
				try? await Task.sleep(for: .milliseconds(50))
			}
		}
		return view
	}

	func updateNSView(_ view: GhosttySurfaceNSView, context _: Context) {
		view.setPaneFocusRequested(isFocused)
	}

	static func dismantleNSView(_: GhosttySurfaceNSView, coordinator: Coordinator) {
		coordinator.registrationTask?.cancel()
	}
}

private final class WeakSurfaceReference {
	weak var surface: GhosttySurface?

	init(_ surface: GhosttySurface) {
		self.surface = surface
	}
}

private struct ProcessResourceSnapshot: Sendable {
	let processIDs: Set<Int32>
	let residentBytes: UInt64
	let cpuSeconds: TimeInterval

	static func capture(
		rootProcessID: Int32,
		additionalProcessIDs: Set<Int32>
	) throws -> ProcessResourceSnapshot {
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/ps")
		process.arguments = ["-axo", "pid=,ppid=,rss=,time="]
		process.standardOutput = output
		process.standardError = output
		try process.run()
		let data = try output.fileHandleForReading.readToEnd() ?? Data()
		process.waitUntilExit()
		guard process.terminationStatus == 0,
		      let text = String(data: data, encoding: .utf8) else {
			throw GhosttyAcceptanceError.resourceSampleFailed
		}
		let rows = try text.split(whereSeparator: \.isNewline).map(ProcessResourceRow.init)
		var selected = additionalProcessIDs.union([rootProcessID])
		var discoveredDescendant = true
		while discoveredDescendant {
			discoveredDescendant = false
			for row in rows where selected.contains(row.parentProcessID) && !selected.contains(row.processID) {
				selected.insert(row.processID)
				discoveredDescendant = true
			}
		}
		let selectedRows = rows.filter { selected.contains($0.processID) }
		guard selectedRows.count >= additionalProcessIDs.count + 1 else {
			throw GhosttyAcceptanceError.resourceSampleFailed
		}
		return ProcessResourceSnapshot(
			processIDs: Set(selectedRows.map(\.processID)),
			residentBytes: selectedRows.reduce(0) { $0 + UInt64($1.residentKilobytes) * 1_024 },
			cpuSeconds: selectedRows.reduce(0) { $0 + $1.cpuSeconds }
		)
	}
}

private struct ProcessResourceRow: Sendable {
	let processID: Int32
	let parentProcessID: Int32
	let residentKilobytes: Int
	let cpuSeconds: TimeInterval

	init(_ line: Substring) throws {
		let fields = line.split(whereSeparator: \.isWhitespace)
		guard fields.count == 4,
		      let processID = Int32(fields[0]),
		      let parentProcessID = Int32(fields[1]),
		      let residentKilobytes = Int(fields[2]),
		      let cpuSeconds = Self.parseCPUTime(fields[3]) else {
			throw GhosttyAcceptanceError.resourceSampleFailed
		}
		self.processID = processID
		self.parentProcessID = parentProcessID
		self.residentKilobytes = residentKilobytes
		self.cpuSeconds = cpuSeconds
	}

	private static func parseCPUTime(_ value: Substring) -> TimeInterval? {
		let dayParts = value.split(separator: "-", maxSplits: 1)
		let daySeconds: TimeInterval
		let timePart: Substring
		if dayParts.count == 2 {
			guard let days = TimeInterval(dayParts[0]) else { return nil }
			daySeconds = days * 86_400
			timePart = dayParts[1]
		} else {
			daySeconds = 0
			timePart = value
		}
		let components = timePart.split(separator: ":").reversed()
		var total = daySeconds
		for (index, component) in components.enumerated() {
			guard let part = TimeInterval(component) else { return nil }
			total += part * pow(60, Double(index))
		}
		return total
	}
}

private enum LocalSSHAvailability {
	static func probe() async -> Bool {
		await Task.detached {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			process.arguments = [
				"-o", "BatchMode=yes",
				"-o", "ConnectTimeout=3",
				"-o", "StrictHostKeyChecking=no",
				"-o", "UserKnownHostsFile=/dev/null",
				"-o", "LogLevel=ERROR",
				"localhost", "true",
			]
			process.standardInput = FileHandle.nullDevice
			process.standardOutput = FileHandle.nullDevice
			process.standardError = FileHandle.nullDevice
			do {
				try process.run()
				process.waitUntilExit()
				return process.terminationStatus == 0
			} catch {
				return false
			}
		}.value
	}
}

private struct AvailableLocalPreflight: PreflightProbing {
	func probe(host _: String, port _: UInt16, timeout _: TimeInterval) async -> PreflightOutcome {
		.ok
	}

	func probeLocalBind(address _: String, port _: UInt16) async -> PortBindOutcome {
		.available
	}
}

@MainActor
private func waitUntil(
	timeout: TimeInterval = 5,
	pollInterval: Duration = .milliseconds(50),
	timeoutError: GhosttyAcceptanceError = .timedOut,
	condition: @MainActor () -> Bool
) async throws {
	let deadline = Date().addingTimeInterval(timeout)
	while !condition() {
		guard Date() < deadline else { throw timeoutError }
		try await Task.sleep(for: pollInterval)
	}
}

private func shellQuote(_ value: String) -> String {
	"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private extension NSView {
	var productionDescendants: [NSView] {
		subviews + subviews.flatMap(\.productionDescendants)
	}
}

private enum GhosttyAcceptanceError: Error {
	case attachmentTimedOut
	case broadcastTimedOut
	case inputTimedOut
	case invalidProcessID
	case missingSurface
	case reconnectInputTimedOut
	case reconnectTeardownTimedOut
	case reconnectTimedOut
	case resourceSampleFailed
	case sessionDidNotAuthenticate
	case surfaceDiscoveryTimedOut
	case teardownTimedOut
	case timedOut
}
