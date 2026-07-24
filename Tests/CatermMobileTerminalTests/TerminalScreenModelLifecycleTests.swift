#if canImport(UIKit)
import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

private actor SessionFactoryLatch {
	private var continuation: CheckedContinuation<SSHTerminalSession, Never>?
	private var waiting = false

	func wait() async -> SSHTerminalSession {
		waiting = true
		return await withCheckedContinuation { continuation = $0 }
	}

	func waitUntilRequested() async {
		while !waiting { await Task.yield() }
	}

	func release(_ session: SSHTerminalSession) {
		continuation?.resume(returning: session)
		continuation = nil
	}
}

private final class RecordingMobileTransport: SSHChannelTransport, @unchecked Sendable {
	private let lock = NSLock()
	private var starts = 0

	func start(onEvent _: @escaping @Sendable (SSHTransportEvent) -> Void) {
		lock.withLock { starts += 1 }
	}

	func write(_: [UInt8]) {}
	func resize(_: TerminalResize.Grid) {}
	func close() {}

	func startCount() -> Int { lock.withLock { starts } }
}

@MainActor
final class TerminalScreenModelLifecycleTests: XCTestCase {
	func testDisconnectCancelsPendingFactoryBeforeTransportStarts() async {
		let host = SSHHost(
			name: "fixture",
			hostname: "fixture.example.com",
			username: "fixture",
			credential: .agent
		)
		let transport = RecordingMobileTransport()
		let session = SSHTerminalSession(host: host, transport: transport)
		let latch = SessionFactoryLatch()
		let model = TerminalScreenModel(host: host) { _ in
			await latch.wait()
		}

		model.start()
		await latch.waitUntilRequested()
		model.disconnect()
		await latch.release(session)
		for _ in 0..<10 { await Task.yield() }

		XCTAssertEqual(transport.startCount(), 0)
	}
}
#endif
