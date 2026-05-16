import Network
import SSHCommandBuilder
import XCTest
@testable import SessionStore

final class PreflightLocalBindTests: XCTestCase {

	/// Spins up an NWListener on an ephemeral port and waits until it reaches
	/// `.ready` before returning the assigned port. Polling `listener.port`
	/// alone is insufficient — the port may be assigned before the socket is
	/// fully bound, or never reported if the listener never reaches ready.
	private func startEphemeralListener() async throws -> (NWListener, UInt16) {
		let listener = try NWListener(using: .tcp, on: .any)
		// Network framework requires a newConnectionHandler before start —
		// otherwise the listener immediately transitions to .failed(EINVAL).
		listener.newConnectionHandler = { conn in conn.cancel() }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let resumed = OneShot()
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					if resumed.markIfFirst() { continuation.resume() }
				case .failed(let error):
					if resumed.markIfFirst() { continuation.resume(throwing: error) }
				default:
					break
				}
			}
			listener.start(queue: .global())
		}
		guard let port = listener.port?.rawValue else {
			listener.cancel()
			throw NSError(domain: "PreflightLocalBindTests", code: -1,
			              userInfo: [NSLocalizedDescriptionKey: "Listener ready but port is nil"])
		}
		return (listener, port)
	}

	func test_freePort_returnsAvailable() async throws {
		// Acquire a known-free port via ephemeral allocation, release it, then
		// probe the same port. Small race window where another process grabs
		// the port is acceptable for a smoke-level test.
		let (listener, port) = try await startEphemeralListener()
		listener.cancel()
		// Brief wait for the OS to release the port.
		try await Task.sleep(nanoseconds: 50_000_000)

		let outcome = await Preflight().probeLocalBind(address: "127.0.0.1", port: port)
		XCTAssertEqual(outcome, .available)
	}

	func test_occupiedPort_returnsAlreadyInUse() async throws {
		let (listener, port) = try await startEphemeralListener()
		defer { listener.cancel() }

		let outcome = await Preflight().probeLocalBind(address: "127.0.0.1", port: port)
		XCTAssertEqual(outcome, .unavailable(.alreadyInUse))
	}
}

/// Thread-safe one-shot flag for listener readiness continuation.
private final class OneShot: @unchecked Sendable {
	private let lock = NSLock()
	private var done = false
	func markIfFirst() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if done { return false }
		done = true
		return true
	}
}
