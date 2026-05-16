import Network
import XCTest
@testable import SessionStore

final class PreflightTests: XCTestCase {

	// MARK: - mapNWError unit tests (pure, no networking)

	func testMapNWErrorECONNREFUSED() {
		let err = NWError.posix(.ECONNREFUSED)
		XCTAssertEqual(Preflight.mapNWError(err), .connectionRefused)
	}

	func testMapNWErrorETIMEDOUT() {
		let err = NWError.posix(.ETIMEDOUT)
		XCTAssertEqual(Preflight.mapNWError(err), .timedOut)
	}

	func testMapNWErrorENETDOWN() {
		XCTAssertEqual(Preflight.mapNWError(.posix(.ENETDOWN)), .networkDown)
		XCTAssertEqual(Preflight.mapNWError(.posix(.ENETUNREACH)), .networkDown)
		XCTAssertEqual(Preflight.mapNWError(.posix(.EHOSTUNREACH)), .networkDown)
	}

	func testMapNWErrorDNSGroupedAsDnsFailed() {
		// NWError.dns wraps a DNSServiceErrorType (Int32). NoSuchRecord = -65554.
		let err = NWError.dns(-65554)
		XCTAssertEqual(Preflight.mapNWError(err), .dnsFailed)
	}

	func testMapNWErrorOtherFallback() {
		// EPERM is unmapped — should land in .other.
		if case let .other(code, message) = Preflight.mapNWError(.posix(.EPERM)) {
			XCTAssertEqual(code, Int(POSIXErrorCode.EPERM.rawValue))
			XCTAssertFalse(message.isEmpty)
		} else {
			XCTFail("Expected .other for EPERM")
		}
	}

	// MARK: - Real NWConnection probe against a local listener

	func testProbeAgainstLocalListenerSucceeds() async throws {
		let listener = try NWListener(using: .tcp, on: .any)
		listener.newConnectionHandler = { conn in
			conn.start(queue: .global())
		}

		// Wait for the listener to reach .ready so the port is accepting
		// connections before we probe it. Polling .port alone is insufficient —
		// the port may be assigned before the socket is fully bound.
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let resumed = ResumedFlagForTest()
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					if resumed.markIfFirst() {
						continuation.resume()
					}
				case .failed(let error):
					if resumed.markIfFirst() {
						continuation.resume(throwing: error)
					}
				default:
					break
				}
			}
			listener.start(queue: .global())
		}
		defer { listener.cancel() }

		guard let port = listener.port else {
			XCTFail("Listener ready but port is nil")
			return
		}

		let outcome = await Preflight().probe(host: "127.0.0.1",
		                                      port: port.rawValue,
		                                      timeout: 2)
		XCTAssertEqual(outcome, .ok)
	}

	func testProbeAgainstUnboundPortReturnsConnectionRefused() async {
		// Port 1 on 127.0.0.1 is essentially never listening on macOS.
		let outcome = await Preflight().probe(host: "127.0.0.1", port: 1, timeout: 2)
		XCTAssertEqual(outcome, .failed(.connectionRefused))
	}
}

// MARK: - Test helpers

/// Thread-safe one-shot flag for listener readiness continuation.
private final class ResumedFlagForTest: @unchecked Sendable {
	private let lock = NSLock()
	private var done = false
	func markIfFirst() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if done { return false }
		done = true
		return true
	}
}
