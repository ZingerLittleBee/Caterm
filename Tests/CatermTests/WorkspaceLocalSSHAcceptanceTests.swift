import AppKit
import Foundation
import SwiftUI
import WorkspaceBroadcast
import WorkspaceCore
import WorkspaceTemplateStore
import XCTest
@testable import Caterm

@MainActor
final class WorkspaceLocalSSHTransportAcceptanceTests: XCTestCase {
	func testFourLocalSSHTransportsStayIsolatedAcrossFocusSaveBroadcastReconnectAndClose() async throws {
		try await requireLocalSSH()
		let hostIDs = (0..<4).map { _ in UUID() }
		var workspace = try makeWorkspace(hostIDs: hostIDs)
		let panes = workspace.topology.panes
		var runtime = WorkspaceRuntimeMap()
		var surfaces: [PaneID: LocalSSHSurface] = [:]
		var originalOutputs: [PaneID: String] = [:]

		for (index, pane) in panes.enumerated() {
			let surface = try LocalSSHSurface()
			surfaces[pane.id] = surface
			try runtime.bind(sessionID: surface.id, to: pane.id, in: workspace)
			try await surface.send("printf 'surface-\(index)\\n'")
		}
		for surface in surfaces.values {
			let isRunning = await surface.isRunning
			XCTAssertTrue(isRunning)
		}

		var focusedPaneIDs: Set<PaneID> = [workspace.activePaneID]
		for _ in 1..<panes.count {
			workspace = workspace.cyclingFocus(.next)
			focusedPaneIDs.insert(workspace.activePaneID)
		}
		XCTAssertEqual(focusedPaneIDs, Set(panes.map(\.id)))

		let template = try WorkspaceTemplate(workspace: workspace, name: "Four local surfaces")
		let reopened = try template.instantiate(availableHostIDs: Set(hostIDs))
		XCTAssertNotEqual(reopened.workspace.id, workspace.id)
		XCTAssertEqual(reopened.workspace.topology.paneCount, 4)
		XCTAssertEqual(reopened.workspace.presentation, workspace.presentation)

		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspace.id,
			source: .command("printf 'broadcast-safe\\n'"),
			recipients: panes.enumerated().map { index, pane in
				WorkspaceBroadcastRecipient(
					workspaceID: workspace.id,
					paneID: pane.id,
					sessionID: try XCTUnwrap(runtime.sessionID(
						for: pane.id,
						in: workspace.id
					)),
					surfaceLeaseID: UUID(),
					paneLabel: "Pane \(index + 1)",
					hostName: "Localhost \(index + 1)",
					address: "localhost"
				)
			}
		)
		let broadcast = WorkspaceBroadcastSession()
		broadcast.arm(plan)
		await broadcast.deliver(
			eligibility: { _ in .eligible },
			send: { recipient, text in
				guard let surface = surfaces[recipient.paneID] else {
					throw LocalSSHError.missingSurface
				}
				try await surface.send(text)
			}
		)
		XCTAssertEqual(
			broadcast.latestReport?.outcomes.map(\.status),
			Array(repeating: .delivered, count: 4)
		)

		let reconnectPane = panes[1]
		let oldSessionID = try XCTUnwrap(runtime.unbind(
			paneID: reconnectPane.id,
			in: workspace.id
		))
		let disconnected = try XCTUnwrap(surfaces.removeValue(forKey: reconnectPane.id))
		originalOutputs[reconnectPane.id] = try await disconnected.finish()
		let replacement = try LocalSSHSurface()
		surfaces[reconnectPane.id] = replacement
		try runtime.bind(sessionID: replacement.id, to: reconnectPane.id, in: workspace)
		try await replacement.send("printf 'reconnected-1\\n'")
		XCTAssertNotEqual(oldSessionID, replacement.id)

		workspace = try workspace.activatingPane(panes[3].id)
		let closeResult = workspace.closingActivePane()
		XCTAssertFalse(closeResult.shouldCloseWindow)
		let closedSessionID = runtime.unbind(
			paneID: closeResult.closedPaneID,
			in: workspace.id
		)
		XCTAssertNotNil(closedSessionID)
		XCTAssertNil(runtime.unbind(
			paneID: closeResult.closedPaneID,
			in: workspace.id
		))
		let closedSurface = try XCTUnwrap(surfaces.removeValue(forKey: closeResult.closedPaneID))
		originalOutputs[closeResult.closedPaneID] = try await closedSurface.finish()

		for (paneID, surface) in surfaces {
			originalOutputs[paneID, default: ""] += try await surface.finish()
		}
		for (index, pane) in panes.enumerated() {
			let output = try XCTUnwrap(originalOutputs[pane.id])
			XCTAssertTrue(output.contains("surface-\(index)\n"))
			XCTAssertTrue(output.contains("broadcast-safe\n"))
			for otherIndex in 0..<panes.count where otherIndex != index {
				XCTAssertFalse(output.contains("surface-\(otherIndex)\n"))
			}
		}
		XCTAssertTrue(originalOutputs[reconnectPane.id]?.contains("reconnected-1\n") == true)
		for surface in surfaces.values {
			let isRunning = await surface.isRunning
			XCTAssertFalse(isRunning)
		}
	}

	func testEightLocalSSHTransportProcessesExposeResourceInputReconnectAndTeardownEvidence() async throws {
		try await requireLocalSSH()
		let hostIDs = (0..<8).map { _ in UUID() }
		let workspace = try makeWorkspace(hostIDs: hostIDs)
		var surfaces = try (0..<8).map { _ in try LocalSSHSurface() }
		var runtime = WorkspaceRuntimeMap()
		for (pane, surface) in zip(workspace.topology.panes, surfaces) {
			try runtime.bind(sessionID: surface.id, to: pane.id, in: workspace)
		}
		XCTAssertEqual(surfaces.count, 8)
		for surface in surfaces {
			let isRunning = await surface.isRunning
			XCTAssertTrue(isRunning)
		}

		let processIDs = surfaces.map(\.processIdentifier)
		let samples = try await Task.detached {
			try LocalSSHResourceSampler.sample(processIDs: processIDs)
		}.value
		XCTAssertEqual(samples.count, 8)
		XCTAssertTrue(samples.allSatisfy { $0.residentKilobytes > 0 })
		XCTAssertTrue(samples.allSatisfy { $0.cpuPercent >= 0 })
		XCTAssertLessThan(
			samples.reduce(0) { $0 + $1.residentKilobytes },
			1_048_576,
			"Eight idle SSH processes should remain below 1 GiB resident memory"
		)
		XCTAssertLessThanOrEqual(
			samples.reduce(0) { $0 + $1.cpuPercent },
			800,
			"Eight idle SSH processes should not exceed eight fully occupied cores"
		)

		let coordinator = NativeWorkspaceTreeView.Coordinator { _, _ in }
		let container = WorkspaceTreeContainerView(
			frame: CGRect(x: 0, y: 0, width: 1_000, height: 650)
		)
		let window = NSWindow(
			contentRect: container.frame,
			styleMask: [.titled, .resizable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = container
		coordinator.update(
			container,
			topology: workspace.topology,
			activePaneID: workspace.activePaneID,
			presentation: .split,
			paneContent: { pane in AnyView(Text(pane.id.rawValue.uuidString)) },
			onRatioChange: { _, _ in }
		)
		for size in [
			CGSize(width: 1_800, height: 1_000),
			CGSize(width: 1_000, height: 650),
			CGSize(width: 1_440, height: 900),
		] {
			window.setContentSize(size)
			container.layoutSubtreeIfNeeded()
			let paneHosts = container.allDescendants.compactMap {
				$0 as? NSHostingView<AnyView>
			}
			XCTAssertEqual(paneHosts.count, 8)
			XCTAssertEqual(Set(paneHosts.map(ObjectIdentifier.init)).count, 8)
			XCTAssertTrue(paneHosts.allSatisfy {
				$0.frame.width.isFinite && $0.frame.height.isFinite
					&& $0.frame.width >= 0 && $0.frame.height >= 0
			})
		}

		for (index, surface) in surfaces.enumerated() {
			try await surface.send("printf 'eight-surface-\(index)\\n'")
		}

		let disconnected = surfaces.removeLast()
		let disconnectedPane = workspace.topology.panes[7]
		XCTAssertEqual(
			runtime.unbind(paneID: disconnectedPane.id, in: workspace.id),
			disconnected.id
		)
		let disconnectedOutput = try await disconnected.finish()
		XCTAssertTrue(disconnectedOutput.contains("eight-surface-7\n"))
		let replacement = try LocalSSHSurface()
		try runtime.bind(
			sessionID: replacement.id,
			to: disconnectedPane.id,
			in: workspace
		)
		try await replacement.send("printf 'eight-surface-reconnected\\n'")
		surfaces.append(replacement)
		XCTAssertEqual(surfaces.count, 8)
		for surface in surfaces {
			let isRunning = await surface.isRunning
			XCTAssertTrue(isRunning)
		}

		var outputs: [String] = []
		for surface in surfaces {
			outputs.append(try await surface.finish())
		}
		for index in 0..<7 {
			XCTAssertTrue(outputs.contains { $0.contains("eight-surface-\(index)\n") })
		}
		XCTAssertTrue(outputs.contains { $0.contains("eight-surface-reconnected\n") })
		for surface in surfaces {
			let isRunning = await surface.isRunning
			XCTAssertFalse(isRunning)
		}
		window.close()
	}

	private func requireLocalSSH() async throws {
		let available = await Task.detached {
			LocalSSHSurface.isAvailable
		}.value
		guard available else {
			throw XCTSkip("Local SSH is unavailable on this host.")
		}
	}

	private func makeWorkspace(hostIDs: [UUID]) throws -> Workspace {
		guard let firstHostID = hostIDs.first else { throw LocalSSHError.missingHost }
		var workspace = Workspace.onePane(host: .saved(id: firstHostID))
		for (index, hostID) in hostIDs.dropFirst().enumerated() {
			workspace = try workspace.splittingActivePane(index.isMultiple(of: 2) ? .right : .down)
			workspace = try workspace.assigningHost(.saved(id: hostID), to: workspace.activePaneID)
		}
		return workspace
	}
}

private extension NSView {
	var allDescendants: [NSView] {
		subviews + subviews.flatMap(\.allDescendants)
	}
}

private actor LocalSSHSurface {
	nonisolated let id = UUID()
	nonisolated let processIdentifier: Int32
	private let process: Process
	private let input: Pipe
	private let output: Pipe
	private var finished = false

	var isRunning: Bool { process.isRunning }

	static var isAvailable: Bool {
		do {
			let probe = Process()
			probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			probe.arguments = sshArguments + ["true"]
			probe.standardInput = FileHandle.nullDevice
			probe.standardOutput = FileHandle.nullDevice
			probe.standardError = FileHandle.nullDevice
			try probe.run()
			probe.waitUntilExit()
			return probe.terminationStatus == 0
		} catch {
			return false
		}
	}

	private static let sshArguments = [
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=3",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"localhost",
	]

	init() throws {
		process = Process()
		input = Pipe()
		output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = Self.sshArguments + ["/bin/sh"]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = output
		try process.run()
		processIdentifier = process.processIdentifier
	}

	func send(_ command: String) throws {
		guard !finished else { throw LocalSSHError.surfaceFinished }
		guard let data = "\(command)\n".data(using: .utf8) else {
			throw LocalSSHError.invalidUTF8
		}
		try input.fileHandleForWriting.write(contentsOf: data)
	}

	func finish(timeout: Duration = .seconds(5)) async throws -> String {
		guard !finished else { throw LocalSSHError.surfaceFinished }
		try send("exit")
		finished = true
		try input.fileHandleForWriting.close()
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while process.isRunning, clock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		guard !process.isRunning else {
			process.terminate()
			throw LocalSSHError.processTimedOut
		}
		let data = try output.fileHandleForReading.readToEnd() ?? Data()
		guard let text = String(data: data, encoding: .utf8) else {
			throw LocalSSHError.invalidUTF8
		}
		return text
	}

	deinit {
		if process.isRunning { process.terminate() }
	}
}

private struct LocalSSHResourceSample {
	let processID: Int32
	let residentKilobytes: Int
	let cpuPercent: Double
}

private enum LocalSSHResourceSampler {
	static func sample(processIDs: [Int32]) throws -> [LocalSSHResourceSample] {
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/ps")
		process.arguments = [
			"-o", "pid=,rss=,%cpu=",
			"-p", processIDs.map(String.init).joined(separator: ","),
		]
		process.standardOutput = output
		process.standardError = output
		try process.run()
		process.waitUntilExit()
		let data = try output.fileHandleForReading.readToEnd() ?? Data()
		guard process.terminationStatus == 0,
		      let text = String(data: data, encoding: .utf8) else {
			throw LocalSSHError.resourceSampleFailed
		}
		return try text.split(whereSeparator: \.isNewline).map { line in
			let fields = line.split(whereSeparator: \.isWhitespace)
			guard fields.count == 3,
			      let processID = Int32(fields[0]),
			      let residentKilobytes = Int(fields[1]),
			      let cpuPercent = Double(fields[2]) else {
				throw LocalSSHError.resourceSampleFailed
			}
			return LocalSSHResourceSample(
				processID: processID,
				residentKilobytes: residentKilobytes,
				cpuPercent: cpuPercent
			)
		}
	}
}

private enum LocalSSHError: Error {
	case invalidUTF8
	case missingHost
	case missingSurface
	case processTimedOut
	case resourceSampleFailed
	case surfaceFinished
}
