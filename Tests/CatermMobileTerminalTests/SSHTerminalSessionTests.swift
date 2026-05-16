import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

final class FakeTransport: SSHChannelTransport, @unchecked Sendable {
	var sent: [[UInt8]] = []
	var lastResize: TerminalResize.Grid?
	var onEvent: (@Sendable (SSHTransportEvent) -> Void)?
	private(set) var connected = false

	func start(onEvent: @escaping @Sendable (SSHTransportEvent) -> Void) {
		self.onEvent = onEvent
		connected = true
		onEvent(.connected)
	}
	func write(_ bytes: [UInt8]) { sent.append(bytes) }
	func resize(_ grid: TerminalResize.Grid) { lastResize = grid }
	func close() { onEvent?(.closed(reason: "client closed")) }

	func emit(_ e: SSHTransportEvent) { onEvent?(e) }
}

@MainActor
final class SSHTerminalSessionTests: XCTestCase {
	private func host() -> SSHHost {
		SSHHost(id: UUID(), name: "B", hostname: "h", username: "u", credential: .password)
	}

	func testConnectsAndStreamsOutput() async {
		let t = FakeTransport()
		let s = SSHTerminalSession(host: host(), transport: t)
		var states: [SSHTerminalSession.State] = []
		s.onStateChange = { states.append($0) }
		var out: [UInt8] = []
		s.onOutput = { out.append(contentsOf: $0) }

		await s.connect()
		t.emit(.data(Array("hello".utf8)))

		XCTAssertEqual(out, Array("hello".utf8))
		XCTAssertTrue(states.contains(.connecting))
		XCTAssertTrue(states.contains(.connected))
	}

	func testInputForwardsToTransport() async {
		let t = FakeTransport()
		let s = SSHTerminalSession(host: host(), transport: t)
		await s.connect()
		await s.send([0x03])
		XCTAssertEqual(t.sent, [[0x03]])
	}

	func testResizeForwardsWhenChanged() async {
		let t = FakeTransport()
		let s = SSHTerminalSession(host: host(), transport: t)
		await s.connect()
		await s.resize(.init(cols: 80, rows: 24))
		await s.resize(.init(cols: 80, rows: 24))
		await s.resize(.init(cols: 100, rows: 30))
		XCTAssertEqual(t.lastResize, .init(cols: 100, rows: 30))
	}

	func testCloseMovesToDisconnected() async {
		let t = FakeTransport()
		let s = SSHTerminalSession(host: host(), transport: t)
		var states: [SSHTerminalSession.State] = []
		s.onStateChange = { states.append($0) }
		await s.connect()
		t.emit(.closed(reason: "bye"))
		XCTAssertEqual(states.last, .disconnected(reason: "bye"))
	}
}
