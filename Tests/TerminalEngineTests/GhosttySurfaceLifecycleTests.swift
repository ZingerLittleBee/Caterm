import AppKit
import XCTest
@testable import TerminalEngine

@MainActor
final class GhosttySurfaceLifecycleTests: XCTestCase {
	func testCallbackRegistryDoesNotRetainDetachedSurface() async throws {
		let reference = try detachedSurfaceReference()
		for _ in 0..<20 where reference.surface != nil {
			try await Task.sleep(for: .milliseconds(25))
		}

		XCTAssertNil(reference.surface)
	}

	private func detachedSurfaceReference() throws -> WeakGhosttySurfaceReference {
		_ = NSApplication.shared
		let window = NSWindow(
			contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		var terminal: GhosttySurfaceNSView? = GhosttySurfaceNSView(
			command: "/bin/sleep 30"
		)
		window.contentView = terminal
		let surface = try XCTUnwrap(terminal?.surface)
		let reference = WeakGhosttySurfaceReference(surface)

		XCTAssertTrue(GhosttySurface.lookup(surface.raw) === surface)

		window.makeFirstResponder(nil)
		window.contentView = nil
		terminal = nil
		window.close()
		return reference
	}
}

private final class WeakGhosttySurfaceReference {
	weak var surface: GhosttySurface?

	init(_ surface: GhosttySurface) {
		self.surface = surface
	}
}
