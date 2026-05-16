# Mobile SSH Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a real, Termius-style SSH terminal on iOS/iPadOS that connects to real SSH servers, with mobile-first interaction (accessory key bar, gestures, lifecycle UI), verified against a real sshd.

**Architecture:** New isolated SPM library `CatermMobileTerminal` (deps: `NIOSSH`, `SwiftTerm`). Pure testable units (key-bar bytes, resize math, auth plan, known-hosts TOFU) + an `actor` SSH session over a `SSHChannelTransport` seam (real NIOSSH impl integration-verified) + a `SwiftTerm` UIKit bridge + a SwiftUI session screen. macOS `TerminalEngine`/libghostty untouched. `CatermMobile` routes Connect to the new session view.

**Tech Stack:** Swift 5.10, swift-nio / swift-nio-ssh, SwiftTerm, SwiftUI/UIKit, XCTest, xcodegen iOS app, idb for on-device verification.

---

## File Structure

- Modify `Package.swift` — add `swift-nio-ssh` + `SwiftTerm` package deps; add `CatermMobileTerminal` library target + `CatermMobileTerminalTests` test target; add `CatermMobileTerminal` to `CatermMobile` deps.
- Create `Sources/CatermMobileTerminal/TerminalKeyBar.swift` — pure key model + sticky-Ctrl + `bytes(for:)`.
- Create `Sources/CatermMobileTerminal/TerminalResize.swift` — pixel+font → (cols,rows), no-op suppression.
- Create `Sources/CatermMobileTerminal/SSHAuthPlan.swift` — host+available secrets → ordered auth attempts.
- Create `Sources/CatermMobileTerminal/MobileKnownHostsStore.swift` — TOFU evaluate + JSON persistence.
- Create `Sources/CatermMobileTerminal/SSHChannelTransport.swift` — transport seam protocol + events.
- Create `Sources/CatermMobileTerminal/SSHTerminalSession.swift` — `actor` lifecycle state machine over the transport.
- Create `Sources/CatermMobileTerminal/NIOSSHTransport.swift` — real swift-nio-ssh implementation of the seam.
- Create `Sources/CatermMobileTerminal/SwiftTermBridge.swift` — `UIViewRepresentable` over `SwiftTerm.TerminalView`.
- Create `Sources/CatermMobileTerminal/MobileTerminalSessionView.swift` — full-screen Termius-style screen.
- Create `Sources/CatermMobileTerminal/TerminalKeyBarView.swift` — accessory bar SwiftUI view.
- Modify `Sources/CatermMobile/MobileHostsView.swift` — Connect routes to the session view.
- Modify `Sources/CatermMobile/MobileCatermShell.swift` — terminal route renders the session view.
- Create `Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift`
- Create `Tests/CatermMobileTerminalTests/TerminalResizeTests.swift`
- Create `Tests/CatermMobileTerminalTests/SSHAuthPlanTests.swift`
- Create `Tests/CatermMobileTerminalTests/MobileKnownHostsStoreTests.swift`
- Create `Tests/CatermMobileTerminalTests/SSHTerminalSessionTests.swift` — state machine over a fake transport.
- Create `Scripts/dev-sshd.sh` — throwaway local OpenSSH server for real-SSH verification.
- Create `Scripts/ios-ssh-e2e.sh` — build+install+idb-drive+screenshot assertion against the real sshd.

---

## Chunk 1: Dependencies And Target Skeleton

### Task 1: Add packages and isolated terminal target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CatermMobileTerminal/TerminalKeyBar.swift` (stub)
- Test: `Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift` (stub)

- [ ] **Step 1: Write a failing placeholder test**

Create `Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift`:

```swift
@testable import CatermMobileTerminal
import XCTest

final class TerminalKeyBarSmokeTests: XCTestCase {
	func testModuleLinks() {
		XCTAssertEqual(TerminalKeyBar.moduleName, "CatermMobileTerminal")
	}
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter TerminalKeyBarSmokeTests`
Expected: FAIL — no such module `CatermMobileTerminal`.

- [ ] **Step 3: Add packages, target, and stub**

In `Package.swift`, set top-level `dependencies:`:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
```

Add the library product after the `CatermMobile` product line:

```swift
        .library(name: "CatermMobileTerminal", targets: ["CatermMobileTerminal"]),
```

Add the target after the `CatermMobile` target:

```swift
        .target(
            name: "CatermMobileTerminal",
            dependencies: [
                "SSHCommandBuilder",
                "KeychainStore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/CatermMobileTerminal"
        ),
```

Add `"CatermMobileTerminal"` to the `CatermMobile` target's `dependencies` array.

Add the test target after `CatermMobileTests`:

```swift
        .testTarget(
            name: "CatermMobileTerminalTests",
            dependencies: ["CatermMobileTerminal", "SSHCommandBuilder", "KeychainStore"],
            path: "Tests/CatermMobileTerminalTests"
        ),
```

Create `Sources/CatermMobileTerminal/TerminalKeyBar.swift`:

```swift
import Foundation

public enum TerminalKeyBar {
	public static let moduleName = "CatermMobileTerminal"
}
```

- [ ] **Step 4: Run and verify GREEN**

Run: `swift test --filter TerminalKeyBarSmokeTests`
Expected: PASS (SwiftPM resolves the two new packages).

- [ ] **Step 5: Verify iOS still builds**

Run: `make ios-build`
Expected: `** BUILD SUCCEEDED **`. (xcodegen `project.yml` already pulls the `CatermMobile` product; the new transitive deps must compile for `iphonesimulator`.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CatermMobileTerminal Tests/CatermMobileTerminalTests
git commit -m "feat(mobile): add isolated CatermMobileTerminal target with NIOSSH + SwiftTerm"
```

---

## Chunk 2: Pure Interaction & Connection Models (TDD)

### Task 2: TerminalKeyBar — Termius-style accessory key bytes

**Files:**
- Modify: `Sources/CatermMobileTerminal/TerminalKeyBar.swift`
- Test: `Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift`

- [ ] **Step 1: Write failing tests**

Replace `Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift`:

```swift
@testable import CatermMobileTerminal
import XCTest

final class TerminalKeyBarTests: XCTestCase {
	func testPlainKeysMapToBytes() {
		var bar = TerminalKeyBar()
		XCTAssertEqual(bar.bytes(for: .esc), [0x1b])
		XCTAssertEqual(bar.bytes(for: .tab), [0x09])
		XCTAssertEqual(bar.bytes(for: .arrowUp), Array("\u{1b}[A".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowDown), Array("\u{1b}[B".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowRight), Array("\u{1b}[C".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowLeft), Array("\u{1b}[D".utf8))
		XCTAssertEqual(bar.bytes(for: .home), Array("\u{1b}[H".utf8))
		XCTAssertEqual(bar.bytes(for: .end), Array("\u{1b}[F".utf8))
		XCTAssertEqual(bar.bytes(for: .pageUp), Array("\u{1b}[5~".utf8))
		XCTAssertEqual(bar.bytes(for: .pageDown), Array("\u{1b}[6~".utf8))
		XCTAssertEqual(bar.bytes(for: .literal("|")), Array("|".utf8))
	}

	func testStickyCtrlAppliesToNextLetterThenClears() {
		var bar = TerminalKeyBar()
		XCTAssertFalse(bar.isCtrlActive)
		bar.toggleCtrl()
		XCTAssertTrue(bar.isCtrlActive)
		// Ctrl-C => 0x03
		XCTAssertEqual(bar.bytes(for: .literal("c")), [0x03])
		// auto-clears after one use
		XCTAssertFalse(bar.isCtrlActive)
		XCTAssertEqual(bar.bytes(for: .literal("c")), Array("c".utf8))
	}

	func testCtrlOnNonLetterPassesThrough() {
		var bar = TerminalKeyBar()
		bar.toggleCtrl()
		// Ctrl-[ is ESC (0x1b); Ctrl with space => 0x00
		XCTAssertEqual(bar.bytes(for: .literal("[")), [0x1b])
		bar.toggleCtrl()
		XCTAssertEqual(bar.bytes(for: .literal(" ")), [0x00])
	}

	func testDefaultLayoutHasTermiusEssentials() {
		let bar = TerminalKeyBar()
		XCTAssertEqual(bar.primaryRow, [.esc, .ctrl, .tab, .arrowLeft, .arrowUp, .arrowDown, .arrowRight])
		XCTAssertTrue(bar.secondaryRow.contains(.literal("|")))
		XCTAssertTrue(bar.secondaryRow.contains(.home))
		XCTAssertTrue(bar.secondaryRow.contains(.pageUp))
	}
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter TerminalKeyBarTests`
Expected: FAIL — `TerminalKeyBar` has no such members.

- [ ] **Step 3: Implement**

Replace `Sources/CatermMobileTerminal/TerminalKeyBar.swift`:

```swift
import Foundation

public struct TerminalKeyBar: Equatable {
	public static let moduleName = "CatermMobileTerminal"

	public enum Key: Hashable {
		case esc, ctrl, tab
		case arrowUp, arrowDown, arrowLeft, arrowRight
		case home, end, pageUp, pageDown
		case literal(String)
	}

	public private(set) var isCtrlActive = false
	public let primaryRow: [Key] = [.esc, .ctrl, .tab, .arrowLeft, .arrowUp, .arrowDown, .arrowRight]
	public let secondaryRow: [Key] = [
		.literal("-"), .literal("|"), .literal("/"), .literal("~"),
		.home, .end, .pageUp, .pageDown,
	]

	public init() {}

	public mutating func toggleCtrl() { isCtrlActive.toggle() }

	/// Returns the exact bytes to send for a key press, applying and then
	/// clearing sticky Ctrl. `.ctrl` itself toggles and emits nothing.
	public mutating func bytes(for key: Key) -> [UInt8] {
		switch key {
		case .ctrl:
			toggleCtrl()
			return []
		case .esc: return [0x1b]
		case .tab: return [0x09]
		case .arrowUp: return Array("\u{1b}[A".utf8)
		case .arrowDown: return Array("\u{1b}[B".utf8)
		case .arrowRight: return Array("\u{1b}[C".utf8)
		case .arrowLeft: return Array("\u{1b}[D".utf8)
		case .home: return Array("\u{1b}[H".utf8)
		case .end: return Array("\u{1b}[F".utf8)
		case .pageUp: return Array("\u{1b}[5~".utf8)
		case .pageDown: return Array("\u{1b}[6~".utf8)
		case .literal(let s):
			guard isCtrlActive else { return Array(s.utf8) }
			isCtrlActive = false
			return [Self.controlByte(for: s)]
		}
	}

	/// Maps a single character under Ctrl to its control code. Letters
	/// fold case (Ctrl-C == Ctrl-c == 0x03); the canonical xterm range
	/// `@ A..Z [ \ ] ^ _` maps to 0x00..0x1f; space => 0x00.
	static func controlByte(for s: String) -> UInt8 {
		guard let scalar = s.uppercased().unicodeScalars.first else { return 0 }
		let v = scalar.value
		if v == 0x20 { return 0x00 }              // space => NUL
		if (0x40...0x5f).contains(v) { return UInt8(v - 0x40) } // @A..Z[\]^_
		if (0x61...0x7a).contains(v) { return UInt8(v - 0x60) } // a..z (defensive)
		return UInt8(truncatingIfNeeded: v)
	}
}
```

- [ ] **Step 4: Run and verify GREEN**

Run: `swift test --filter TerminalKeyBarTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobileTerminal/TerminalKeyBar.swift Tests/CatermMobileTerminalTests/TerminalKeyBarTests.swift
git commit -m "feat(mobile): add Termius-style terminal key bar byte mapping"
```

### Task 3: TerminalResize — pixel/font → cols/rows

**Files:**
- Create: `Sources/CatermMobileTerminal/TerminalResize.swift`
- Test: `Tests/CatermMobileTerminalTests/TerminalResizeTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/CatermMobileTerminalTests/TerminalResizeTests.swift`:

```swift
@testable import CatermMobileTerminal
import XCTest

final class TerminalResizeTests: XCTestCase {
	func testComputesColsRowsFromCellSize() {
		let r = TerminalResize.grid(
			pixelWidth: 390, pixelHeight: 600, cellWidth: 7.5, cellHeight: 15)
		XCTAssertEqual(r.cols, 52)
		XCTAssertEqual(r.rows, 40)
	}

	func testClampsToMinimums() {
		let r = TerminalResize.grid(
			pixelWidth: 1, pixelHeight: 1, cellWidth: 7.5, cellHeight: 15)
		XCTAssertEqual(r.cols, 2)
		XCTAssertEqual(r.rows, 1)
	}

	func testSuppressesNoOpChange() {
		var last: TerminalResize.Grid? = TerminalResize.Grid(cols: 80, rows: 24)
		let same = TerminalResize.Grid(cols: 80, rows: 24)
		XCTAssertFalse(TerminalResize.shouldSend(same, since: last))
		let changed = TerminalResize.Grid(cols: 81, rows: 24)
		XCTAssertTrue(TerminalResize.shouldSend(changed, since: last))
		last = nil
		XCTAssertTrue(TerminalResize.shouldSend(same, since: last))
	}
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter TerminalResizeTests`
Expected: FAIL — no `TerminalResize`.

- [ ] **Step 3: Implement**

Create `Sources/CatermMobileTerminal/TerminalResize.swift`:

```swift
import CoreGraphics
import Foundation

public enum TerminalResize {
	public struct Grid: Equatable {
		public var cols: Int
		public var rows: Int
		public init(cols: Int, rows: Int) {
			self.cols = cols
			self.rows = rows
		}
	}

	public static func grid(
		pixelWidth: CGFloat,
		pixelHeight: CGFloat,
		cellWidth: CGFloat,
		cellHeight: CGFloat
	) -> Grid {
		guard cellWidth > 0, cellHeight > 0 else { return Grid(cols: 2, rows: 1) }
		let cols = max(2, Int((pixelWidth / cellWidth).rounded(.down)))
		let rows = max(1, Int((pixelHeight / cellHeight).rounded(.down)))
		return Grid(cols: cols, rows: rows)
	}

	public static func shouldSend(_ next: Grid, since last: Grid?) -> Bool {
		next != last
	}
}
```

- [ ] **Step 4: Run and verify GREEN**

Run: `swift test --filter TerminalResizeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobileTerminal/TerminalResize.swift Tests/CatermMobileTerminalTests/TerminalResizeTests.swift
git commit -m "feat(mobile): add terminal resize grid math"
```

### Task 4: SSHAuthPlan — ordered auth attempts from host + secrets

**Files:**
- Create: `Sources/CatermMobileTerminal/SSHAuthPlan.swift`
- Test: `Tests/CatermMobileTerminalTests/SSHAuthPlanTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/CatermMobileTerminalTests/SSHAuthPlanTests.swift`:

```swift
import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

final class SSHAuthPlanTests: XCTestCase {
	private func host(_ c: CredentialSource) -> SSHHost {
		SSHHost(id: UUID(), name: "B", hostname: "h", username: "u", credential: c)
	}

	func testPasswordHostWithSecretUsesPassword() {
		let p = SSHAuthPlan.make(
			host: host(.password),
			password: "pw", keyBlob: nil, passphrase: nil)
		XCTAssertEqual(p.attempts, [.password("pw")])
		XCTAssertNil(p.missing)
	}

	func testPasswordHostWithoutSecretIsMissing() {
		let p = SSHAuthPlan.make(
			host: host(.password), password: nil, keyBlob: nil, passphrase: nil)
		XCTAssertTrue(p.attempts.isEmpty)
		XCTAssertEqual(p.missing, .password)
	}

	func testKeyFileWithPassphraseUsesKeyThenPassword() {
		let p = SSHAuthPlan.make(
			host: host(.keyFile(keyPath: "/k", hasPassphrase: true)),
			password: nil, keyBlob: Data([1, 2, 3]), passphrase: "pp")
		XCTAssertEqual(p.attempts, [.privateKey(blob: Data([1, 2, 3]), passphrase: "pp")])
		XCTAssertNil(p.missing)
	}

	func testKeyFileMissingPassphraseIsMissing() {
		let p = SSHAuthPlan.make(
			host: host(.keyFile(keyPath: "/k", hasPassphrase: true)),
			password: nil, keyBlob: Data([1]), passphrase: nil)
		XCTAssertEqual(p.missing, .passphrase)
	}

	func testAgentHostFallsBackToKeyboardInteractive() {
		let p = SSHAuthPlan.make(
			host: host(.agent), password: nil, keyBlob: nil, passphrase: nil)
		XCTAssertEqual(p.attempts, [.keyboardInteractive])
		XCTAssertNil(p.missing)
	}
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SSHAuthPlanTests`
Expected: FAIL — no `SSHAuthPlan`.

- [ ] **Step 3: Implement**

Create `Sources/CatermMobileTerminal/SSHAuthPlan.swift`:

```swift
import Foundation
import SSHCommandBuilder

public struct SSHAuthPlan: Equatable {
	public enum Attempt: Equatable {
		case password(String)
		case privateKey(blob: Data, passphrase: String?)
		case keyboardInteractive
	}

	public enum Missing: Equatable {
		case password
		case passphrase
		case keyBlob
	}

	public let attempts: [Attempt]
	public let missing: Missing?

	public static func make(
		host: SSHHost,
		password: String?,
		keyBlob: Data?,
		passphrase: String?
	) -> SSHAuthPlan {
		switch host.credential {
		case .password:
			if let password {
				return SSHAuthPlan(attempts: [.password(password)], missing: nil)
			}
			return SSHAuthPlan(attempts: [], missing: .password)
		case .keyFile(_, let hasPassphrase):
			guard let keyBlob else {
				return SSHAuthPlan(attempts: [], missing: .keyBlob)
			}
			if hasPassphrase, passphrase == nil {
				return SSHAuthPlan(attempts: [], missing: .passphrase)
			}
			return SSHAuthPlan(
				attempts: [.privateKey(blob: keyBlob, passphrase: passphrase)],
				missing: nil)
		case .agent:
			// No agent forwarding on iOS; fall back to interactive.
			return SSHAuthPlan(attempts: [.keyboardInteractive], missing: nil)
		}
	}
}
```

- [ ] **Step 4: Run and verify GREEN**

Run: `swift test --filter SSHAuthPlanTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobileTerminal/SSHAuthPlan.swift Tests/CatermMobileTerminalTests/SSHAuthPlanTests.swift
git commit -m "feat(mobile): add SSH auth plan derivation"
```

### Task 5: MobileKnownHostsStore — TOFU host-key trust

**Files:**
- Create: `Sources/CatermMobileTerminal/MobileKnownHostsStore.swift`
- Test: `Tests/CatermMobileTerminalTests/MobileKnownHostsStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/CatermMobileTerminalTests/MobileKnownHostsStoreTests.swift`:

```swift
@testable import CatermMobileTerminal
import XCTest

final class MobileKnownHostsStoreTests: XCTestCase {
	private func tmp() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("kh-\(UUID().uuidString).json")
	}

	func testUnknownThenTrustThenTrusted() throws {
		let url = tmp()
		let s = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .unknown)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
		// persisted across instances
		let s2 = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(s2.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
	}

	func testMismatchAfterTrust() throws {
		let url = tmp()
		let s = MobileKnownHostsStore(fileURL: url)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "BBB"), .mismatch)
	}
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter MobileKnownHostsStoreTests`
Expected: FAIL — no `MobileKnownHostsStore`.

- [ ] **Step 3: Implement**

Create `Sources/CatermMobileTerminal/MobileKnownHostsStore.swift`:

```swift
import Foundation

public final class MobileKnownHostsStore {
	public enum Verdict: Equatable {
		case trusted
		case unknown
		case mismatch
	}

	private let fileURL: URL
	private var map: [String: String]

	public init(fileURL: URL) {
		self.fileURL = fileURL
		if let data = try? Data(contentsOf: fileURL),
		   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
			self.map = decoded
		} else {
			self.map = [:]
		}
	}

	public func evaluate(endpoint: String, fingerprint: String) -> Verdict {
		guard let known = map[endpoint] else { return .unknown }
		return known == fingerprint ? .trusted : .mismatch
	}

	public func trust(endpoint: String, fingerprint: String) throws {
		map[endpoint] = fingerprint
		let data = try JSONEncoder().encode(map)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true)
		try data.write(to: fileURL)
	}
}
```

- [ ] **Step 4: Run and verify GREEN**

Run: `swift test --filter MobileKnownHostsStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobileTerminal/MobileKnownHostsStore.swift Tests/CatermMobileTerminalTests/MobileKnownHostsStoreTests.swift
git commit -m "feat(mobile): add TOFU known-hosts store"
```

---

## Chunk 3: Session State Machine Over A Transport Seam

### Task 6: SSHChannelTransport seam + SSHTerminalSession state machine

**Files:**
- Create: `Sources/CatermMobileTerminal/SSHChannelTransport.swift`
- Create: `Sources/CatermMobileTerminal/SSHTerminalSession.swift`
- Test: `Tests/CatermMobileTerminalTests/SSHTerminalSessionTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/CatermMobileTerminalTests/SSHTerminalSessionTests.swift`:

```swift
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
		await s.resize(.init(cols: 80, rows: 24)) // no-op
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
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SSHTerminalSessionTests`
Expected: FAIL — no `SSHChannelTransport` / `SSHTerminalSession`.

- [ ] **Step 3: Implement the seam**

Create `Sources/CatermMobileTerminal/SSHChannelTransport.swift`:

```swift
import Foundation

public enum SSHTransportEvent: Sendable {
	case connecting
	case hostKeyPrompt(endpoint: String, fingerprint: String)
	case authPrompt(SSHAuthPlan.Missing)
	case connected
	case data([UInt8])
	case failed(reason: String)
	case closed(reason: String)
}

/// Abstraction over a live SSH shell channel so the session state
/// machine is unit-testable without a server. Real impl: NIOSSHTransport.
public protocol SSHChannelTransport: AnyObject, Sendable {
	func start(onEvent: @escaping @Sendable (SSHTransportEvent) -> Void)
	func write(_ bytes: [UInt8])
	func resize(_ grid: TerminalResize.Grid)
	func close()
}
```

- [ ] **Step 4: Implement the session**

Create `Sources/CatermMobileTerminal/SSHTerminalSession.swift`:

```swift
import Foundation
import SSHCommandBuilder

@MainActor
public final class SSHTerminalSession {
	public enum State: Equatable {
		case idle
		case connecting
		case hostKeyPrompt(endpoint: String, fingerprint: String)
		case authPrompt(SSHAuthPlan.Missing)
		case connected
		case failed(reason: String)
		case disconnected(reason: String)
	}

	public let host: SSHHost
	private let transport: SSHChannelTransport
	private var lastGrid: TerminalResize.Grid?

	public private(set) var state: State = .idle {
		didSet { if state != oldValue { onStateChange?(state) } }
	}

	public var onStateChange: ((State) -> Void)?
	public var onOutput: (([UInt8]) -> Void)?

	public init(host: SSHHost, transport: SSHChannelTransport) {
		self.host = host
		self.transport = transport
	}

	public func connect() async {
		state = .connecting
		transport.start { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
	}

	public func send(_ bytes: [UInt8]) async {
		guard !bytes.isEmpty else { return }
		transport.write(bytes)
	}

	public func resize(_ grid: TerminalResize.Grid) async {
		guard TerminalResize.shouldSend(grid, since: lastGrid) else { return }
		lastGrid = grid
		transport.resize(grid)
	}

	public func disconnect() async {
		transport.close()
	}

	private func handle(_ event: SSHTransportEvent) {
		switch event {
		case .connecting:
			state = .connecting
		case let .hostKeyPrompt(endpoint, fingerprint):
			state = .hostKeyPrompt(endpoint: endpoint, fingerprint: fingerprint)
		case let .authPrompt(missing):
			state = .authPrompt(missing)
		case .connected:
			state = .connected
		case let .data(bytes):
			onOutput?(bytes)
		case let .failed(reason):
			state = .failed(reason: reason)
		case let .closed(reason):
			state = .disconnected(reason: reason)
		}
	}
}
```

- [ ] **Step 5: Run and verify GREEN**

Run: `swift test --filter SSHTerminalSessionTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/CatermMobileTerminal/SSHChannelTransport.swift Sources/CatermMobileTerminal/SSHTerminalSession.swift Tests/CatermMobileTerminalTests/SSHTerminalSessionTests.swift
git commit -m "feat(mobile): add SSH session state machine over transport seam"
```

---

## Chunk 4: Real NIOSSH Transport

### Task 7: NIOSSHTransport — swift-nio-ssh implementation

**Files:**
- Create: `Sources/CatermMobileTerminal/NIOSSHTransport.swift`

> No unit test: this is the integration boundary, exercised by the real-SSH e2e in Chunk 6. Correctness gate here is "compiles for iОS + connects to real sshd in Task 12".

- [ ] **Step 1: Implement the NIOSSH transport**

Create `Sources/CatermMobileTerminal/NIOSSHTransport.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHCommandBuilder

/// Live SSH shell channel using swift-nio-ssh. One connection, one
/// `.session` child channel with a PTY + shell. All NIO callbacks are
/// hopped to the provided event sink.
public final class NIOSSHTransport: SSHChannelTransport, @unchecked Sendable {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let knownHosts: MobileKnownHostsStore
	private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	private var connection: Channel?
	private var child: Channel?
	private var sink: (@Sendable (SSHTransportEvent) -> Void)?

	public init(host: SSHHost, plan: SSHAuthPlan, knownHosts: MobileKnownHostsStore) {
		self.host = host
		self.plan = plan
		self.knownHosts = knownHosts
	}

	public func start(onEvent: @escaping @Sendable (SSHTransportEvent) -> Void) {
		self.sink = onEvent
		onEvent(.connecting)

		let userAuth = NIOSSHAuthDelegate(host: host, plan: plan, sink: onEvent)
		let serverAuth = NIOSSHHostKeyDelegate(
			endpoint: "\(host.hostname):\(host.port)",
			knownHosts: knownHosts, sink: onEvent)

		let bootstrap = ClientBootstrap(group: group)
			.channelInitializer { channel in
				channel.pipeline.addHandlers([
					NIOSSHHandler(
						role: .client(.init(
							userAuthDelegate: userAuth,
							serverAuthDelegate: serverAuth)),
						allocator: channel.allocator,
						inboundChildChannelInitializer: nil),
				])
			}
			.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

		bootstrap.connect(host: host.hostname, port: host.port).whenComplete { result in
			switch result {
			case .failure(let error):
				onEvent(.failed(reason: "connect: \(error)"))
			case .success(let channel):
				self.connection = channel
				self.openShell(on: channel, onEvent: onEvent)
			}
		}
	}

	private func openShell(
		on channel: Channel,
		onEvent: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		let promise = channel.eventLoop.makePromise(of: Channel.self)
		channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { ssh in
			ssh.createChannel(promise) { child, _ in
				child.pipeline.addHandler(
					ShellHandler(sink: onEvent, ready: {
						self.child = child
						onEvent(.connected)
					}))
			}
		}
		promise.futureResult.whenFailure { error in
			onEvent(.failed(reason: "channel: \(error)"))
		}
		promise.futureResult.whenSuccess { child in
			let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
				wantReply: true, term: "xterm-256color",
				terminalCharacterWidth: 80, terminalRowHeight: 24,
				terminalPixelWidth: 0, terminalPixelHeight: 0,
				terminalModes: .init([:]))
			child.triggerUserOutboundEvent(pty).whenSuccess {
				let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
				child.triggerUserOutboundEvent(shell, promise: nil)
			}
		}
	}

	public func write(_ bytes: [UInt8]) {
		guard let child else { return }
		var buf = child.allocator.buffer(capacity: bytes.count)
		buf.writeBytes(bytes)
		let data = SSHChannelData(type: .channel, data: .byteBuffer(buf))
		child.writeAndFlush(data, promise: nil)
	}

	public func resize(_ grid: TerminalResize.Grid) {
		guard let child else { return }
		let ev = SSHChannelRequestEvent.WindowChangeRequest(
			terminalCharacterWidth: grid.cols, terminalRowHeight: grid.rows,
			terminalPixelWidth: 0, terminalPixelHeight: 0)
		child.triggerUserOutboundEvent(ev, promise: nil)
	}

	public func close() {
		child?.close(promise: nil)
		connection?.close(promise: nil)
		try? group.syncShutdownGracefully()
		sink?(.closed(reason: "client closed"))
	}
}

private final class ShellHandler: ChannelDuplexHandler {
	typealias InboundIn = SSHChannelData
	typealias OutboundOut = SSHChannelData

	private let sink: @Sendable (SSHTransportEvent) -> Void
	private let ready: () -> Void
	private var announced = false

	init(sink: @escaping @Sendable (SSHTransportEvent) -> Void, ready: @escaping () -> Void) {
		self.sink = sink
		self.ready = ready
	}

	func channelActive(context: ChannelHandlerContext) {
		if !announced { announced = true; ready() }
		context.fireChannelActive()
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let channelData = unwrapInboundIn(data)
		guard case .byteBuffer(let buf) = channelData.data else { return }
		sink(.data(Array(buf.readableBytesView)))
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		sink(.failed(reason: "\(error)"))
		context.close(promise: nil)
	}

	func channelInactive(context: ChannelHandlerContext) {
		sink(.closed(reason: "channel closed"))
		context.fireChannelInactive()
	}
}

private final class NIOSSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let sink: @Sendable (SSHTransportEvent) -> Void

	init(host: SSHHost, plan: SSHAuthPlan, sink: @escaping @Sendable (SSHTransportEvent) -> Void) {
		self.host = host
		self.plan = plan
		self.sink = sink
	}

	func nextAuthenticationType(
		availableMethods: NIOSSHAvailableUserAuthenticationMethods,
		nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
	) {
		if let missing = plan.missing {
			sink(.authPrompt(missing))
			nextChallengePromise.succeed(nil)
			return
		}
		guard let attempt = plan.attempts.first else {
			nextChallengePromise.succeed(nil)
			return
		}
		switch attempt {
		case .password(let pw) where availableMethods.contains(.password):
			nextChallengePromise.succeed(.init(
				username: host.username, serviceName: "",
				offer: .password(.init(password: pw))))
		case .privateKey(let blob, let passphrase):
			do {
				let key = try Self.parsePrivateKey(blob: blob, passphrase: passphrase)
				nextChallengePromise.succeed(.init(
					username: host.username, serviceName: "",
					offer: .privateKey(.init(privateKey: key))))
			} catch {
				sink(.failed(reason: "key parse: \(error)"))
				nextChallengePromise.succeed(nil)
			}
		default:
			nextChallengePromise.succeed(nil)
		}
	}

	static func parsePrivateKey(blob: Data, passphrase: String?) throws -> NIOSSHPrivateKey {
		let pem = String(decoding: blob, as: UTF8.self)
		if let passphrase {
			return try NIOSSHPrivateKey(
				openSSHPrivateKey: pem,
				decryptionKey: Array(passphrase.utf8))
		}
		return try NIOSSHPrivateKey(openSSHPrivateKey: pem)
	}
}

private final class NIOSSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
	private let endpoint: String
	private let knownHosts: MobileKnownHostsStore
	private let sink: @Sendable (SSHTransportEvent) -> Void

	init(endpoint: String, knownHosts: MobileKnownHostsStore, sink: @escaping @Sendable (SSHTransportEvent) -> Void) {
		self.endpoint = endpoint
		self.knownHosts = knownHosts
		self.sink = sink
	}

	func validateHostKey(
		hostKey: NIOSSHPublicKey,
		validationCompletePromise: EventLoopPromise<Void>
	) {
		var hasher = SHA256()
		hostKey.write(to: &hasher)
		let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
		switch knownHosts.evaluate(endpoint: endpoint, fingerprint: fingerprint) {
		case .trusted:
			validationCompletePromise.succeed(())
		case .unknown:
			// TOFU: persist and accept. UI surfaces the fingerprint via the
			// session state for explicit user awareness.
			sink(.hostKeyPrompt(endpoint: endpoint, fingerprint: fingerprint))
			try? knownHosts.trust(endpoint: endpoint, fingerprint: fingerprint)
			validationCompletePromise.succeed(())
		case .mismatch:
			sink(.failed(reason: "host key mismatch for \(endpoint)"))
			validationCompletePromise.fail(NIOSSHError.invalidHostKeyForKeyExchange)
		}
	}
}

import Crypto
```

> NOTE for the implementing engineer: swift-nio-ssh API names occasionally
> shift across versions. If `swift build` reports a signature mismatch
> (e.g. `NIOSSHUserAuthenticationOffer`, `createChannel`,
> `PseudoTerminalRequest` field labels, `NIOSSHPrivateKey(openSSHPrivateKey:)`),
> adjust to the resolved version's API — keep behavior identical and add
> the `Crypto` package (`swift-crypto`) to `Package.swift` if `Crypto` is
> not transitively available (swift-nio-ssh depends on swift-crypto, so it
> usually is; otherwise add `.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")` and `.product(name: "Crypto", package: "swift-crypto")`).

- [ ] **Step 2: Verify it compiles for macOS and iOS**

Run: `swift build --target CatermMobileTerminal`
Expected: build succeeds (fix API drift per the note above until it does).

Run: `make ios-build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CatermMobileTerminal/NIOSSHTransport.swift Package.swift
git commit -m "feat(mobile): add real swift-nio-ssh shell transport"
```

---

## Chunk 5: SwiftTerm Bridge, Session Screen, Key Bar UI

### Task 8: SwiftTermBridge — UIViewRepresentable terminal

**Files:**
- Create: `Sources/CatermMobileTerminal/SwiftTermBridge.swift`

> No unit test: UIKit/SwiftUI view. Verified visually in Chunk 6.

- [ ] **Step 1: Implement the bridge**

Create `Sources/CatermMobileTerminal/SwiftTermBridge.swift`:

```swift
#if canImport(UIKit)
import SwiftTerm
import SwiftUI
import UIKit

/// Wraps SwiftTerm's `TerminalView`. Feeds session output into the
/// emulator and forwards user-typed bytes + size changes back out.
public struct SwiftTermBridge: UIViewRepresentable {
	@ObservedObject var model: TerminalScreenModel

	public init(model: TerminalScreenModel) {
		self.model = model
	}

	public func makeUIView(context: Context) -> TerminalView {
		let tv = TerminalView(frame: .zero)
		tv.terminalDelegate = context.coordinator
		tv.backgroundColor = .black
		context.coordinator.attach(terminalView: tv)
		model.bindTerminal(context.coordinator)
		return tv
	}

	public func updateUIView(_ uiView: TerminalView, context: Context) {}

	public func makeCoordinator() -> TerminalCoordinator {
		TerminalCoordinator(model: model)
	}
}

public final class TerminalCoordinator: NSObject, TerminalViewDelegate {
	private let model: TerminalScreenModel
	weak var terminalView: TerminalView?

	init(model: TerminalScreenModel) {
		self.model = model
	}

	func attach(terminalView: TerminalView) {
		self.terminalView = terminalView
	}

	public func feed(_ bytes: [UInt8]) {
		terminalView?.feed(byteArray: bytes[...])
	}

	public func send(source: TerminalView, data: ArraySlice<UInt8>) {
		Task { await model.session?.send(Array(data)) }
	}

	public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
		Task { await model.session?.resize(.init(cols: newCols, rows: newRows)) }
	}

	public func setTerminalTitle(source: TerminalView, title: String) {}
	public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
	public func scrolled(source: TerminalView, position: Double) {}
	public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
	public func bell(source: TerminalView) {}
	public func clipboardCopy(source: TerminalView, content: Data) {}
	public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
	public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
```

- [ ] **Step 2: Verify iOS build** (after Task 9 adds `TerminalScreenModel`, this compiles)

Deferred to Task 9 Step 4.

### Task 9: TerminalScreenModel + MobileTerminalSessionView + key bar UI

**Files:**
- Create: `Sources/CatermMobileTerminal/MobileTerminalSessionView.swift`
- Create: `Sources/CatermMobileTerminal/TerminalKeyBarView.swift`

- [ ] **Step 1: Implement the screen model**

Create `Sources/CatermMobileTerminal/MobileTerminalSessionView.swift`:

```swift
#if canImport(UIKit)
import KeychainStore
import SSHCommandBuilder
import SwiftUI

@MainActor
public final class TerminalScreenModel: ObservableObject {
	@Published public var state: SSHTerminalSession.State = .idle
	@Published public var keyBar = TerminalKeyBar()
	public private(set) var session: SSHTerminalSession?
	private weak var coordinator: TerminalCoordinator?
	private let make: () -> SSHTerminalSession

	public init(makeSession: @escaping () -> SSHTerminalSession) {
		self.make = makeSession
	}

	func bindTerminal(_ c: TerminalCoordinator) { self.coordinator = c }

	public func start() {
		let s = make()
		s.onStateChange = { [weak self] st in
			Task { @MainActor in self?.state = st }
		}
		s.onOutput = { [weak self] bytes in
			Task { @MainActor in self?.coordinator?.feed(bytes) }
		}
		session = s
		Task { await s.connect() }
	}

	public func tapKey(_ key: TerminalKeyBar.Key) {
		let bytes = keyBar.bytes(for: key)
		guard !bytes.isEmpty else { return }
		Task { await session?.send(bytes) }
	}

	public func disconnect() {
		Task { await session?.disconnect() }
	}
}

public struct MobileTerminalSessionView: View {
	@StateObject private var model: TerminalScreenModel
	@Environment(\.dismiss) private var dismiss
	let title: String

	public init(title: String, makeSession: @escaping () -> SSHTerminalSession) {
		self.title = title
		_model = StateObject(wrappedValue: TerminalScreenModel(makeSession: makeSession))
	}

	public var body: some View {
		VStack(spacing: 0) {
			SwiftTermBridge(model: model)
				.ignoresSafeArea(.container, edges: .bottom)
			TerminalKeyBarView(model: model)
		}
		.navigationTitle(title)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button("Disconnect", role: .destructive) {
					model.disconnect()
					dismiss()
				}
			}
		}
		.overlay { connectionOverlay }
		.onAppear { model.start() }
	}

	@ViewBuilder private var connectionOverlay: some View {
		switch model.state {
		case .connecting, .idle:
			ProgressView("Connecting…")
				.padding()
				.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
		case let .failed(reason):
			ContentUnavailableView("Connection Failed", systemImage: "xmark.octagon", description: Text(reason))
		case let .disconnected(reason):
			ContentUnavailableView("Disconnected", systemImage: "bolt.horizontal.circle", description: Text(reason))
		case let .authPrompt(missing):
			ContentUnavailableView("Credential Needed", systemImage: "key", description: Text("Missing \(String(describing: missing)); set it on the host and reconnect."))
		case .hostKeyPrompt, .connected:
			EmptyView()
		}
	}
}
#endif
```

- [ ] **Step 2: Implement the key bar view**

Create `Sources/CatermMobileTerminal/TerminalKeyBarView.swift`:

```swift
#if canImport(UIKit)
import SwiftUI

struct TerminalKeyBarView: View {
	@ObservedObject var model: TerminalScreenModel

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(Array(model.keyBar.primaryRow.enumerated()), id: \.offset) { _, key in
					keyButton(key)
				}
				Divider().frame(height: 24)
				ForEach(Array(model.keyBar.secondaryRow.enumerated()), id: \.offset) { _, key in
					keyButton(key)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
		}
		.background(.bar)
	}

	@ViewBuilder private func keyButton(_ key: TerminalKeyBar.Key) -> some View {
		Button {
			model.tapKey(key)
		} label: {
			Text(label(for: key))
				.font(.system(.callout, design: .monospaced))
				.frame(minWidth: 34, minHeight: 30)
				.background(
					(key == .ctrl && model.keyBar.isCtrlActive)
						? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
					in: RoundedRectangle(cornerRadius: 6))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(accessibility(for: key))
	}

	private func label(for key: TerminalKeyBar.Key) -> String {
		switch key {
		case .esc: "esc"
		case .ctrl: "ctrl"
		case .tab: "tab"
		case .arrowUp: "↑"
		case .arrowDown: "↓"
		case .arrowLeft: "←"
		case .arrowRight: "→"
		case .home: "home"
		case .end: "end"
		case .pageUp: "pgup"
		case .pageDown: "pgdn"
		case .literal(let s): s
		}
	}

	private func accessibility(for key: TerminalKeyBar.Key) -> String {
		if case .literal(let s) = key { return "Key \(s)" }
		return label(for: key)
	}
}
#endif
```

- [ ] **Step 3: Run unit tests (regression)**

Run: `swift test --filter CatermMobileTerminalTests`
Expected: PASS (all pure-model tests from Chunk 2–3 still green).

- [ ] **Step 4: Verify iOS build**

Run: `make ios-build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobileTerminal/SwiftTermBridge.swift Sources/CatermMobileTerminal/MobileTerminalSessionView.swift Sources/CatermMobileTerminal/TerminalKeyBarView.swift
git commit -m "feat(mobile): add SwiftTerm session screen with Termius key bar"
```

---

## Chunk 6: Wire Connect Route + Real-SSH Verification

### Task 10: Route Connect to the live session

**Files:**
- Modify: `Sources/CatermMobile/MobileHostsView.swift`
- Modify: `Sources/CatermMobile/MobileCatermShell.swift`
- Modify: `Package.swift` (CatermMobile already gains `CatermMobileTerminal` in Task 1)

- [ ] **Step 1: Build a session from a host + keychain**

In `Sources/CatermMobile/MobileHostsView.swift`, add at top:

```swift
import CatermMobileTerminal
import KeychainStore
```

Add this helper to `MobileHostsView` (next to `saveHost`):

```swift
	private func makeSession(for host: SSHHost) -> SSHTerminalSession {
		let kc = KeychainStore(service: MobileCredentialWriter.defaultService, accessGroup: nil)
		let password = try? kc.get(account: MobileCredentialPlan.passwordAccount(host.id))
		let passphrase = try? kc.get(account: MobileCredentialPlan.keyPassphraseAccount(host.id))
		let keyBlob: Data? = {
			if case let .keyFile(path, _) = host.credential {
				return try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
			}
			return nil
		}()
		let plan = SSHAuthPlan.make(
			host: host, password: password, keyBlob: keyBlob, passphrase: passphrase)
		let support = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
		let knownHosts = MobileKnownHostsStore(
			fileURL: support.appendingPathComponent("known_hosts.json"))
		let transport = NIOSSHTransport(host: host, plan: plan, knownHosts: knownHosts)
		return SSHTerminalSession(host: host, transport: transport)
	}
```

- [ ] **Step 2: Replace the terminal placeholder destination**

In `Sources/CatermMobile/MobileHostsView.swift`, in `destination(for:)`, change the `.terminalPlaceholder` case to:

```swift
		case .terminalPlaceholder(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				MobileTerminalSessionView(title: host.name) { makeSession(for: host) }
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
```

In `Sources/CatermMobile/MobileCatermShell.swift`, add `import CatermMobileTerminal` at top, and in `MobileShellDetail.body` change the `.terminal(let id)` case to:

```swift
		case .terminal(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				MobileTerminalSessionView(title: host.name) {
					MobileHostsView.liveSession(for: host)
				}
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
```

Promote the helper to a `static` factory so both call sites share it: in
`MobileHostsView.swift` replace `private func makeSession` with:

```swift
	static func liveSession(for host: SSHHost) -> SSHTerminalSession {
		let kc = KeychainStore(service: MobileCredentialWriter.defaultService, accessGroup: nil)
		let password = try? kc.get(account: MobileCredentialPlan.passwordAccount(host.id))
		let passphrase = try? kc.get(account: MobileCredentialPlan.keyPassphraseAccount(host.id))
		let keyBlob: Data? = {
			if case let .keyFile(path, _) = host.credential {
				return try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
			}
			return nil
		}()
		let plan = SSHAuthPlan.make(
			host: host, password: password, keyBlob: keyBlob, passphrase: passphrase)
		let support = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
		let knownHosts = MobileKnownHostsStore(
			fileURL: support.appendingPathComponent("known_hosts.json"))
		let transport = NIOSSHTransport(host: host, plan: plan, knownHosts: knownHosts)
		return SSHTerminalSession(host: host, transport: transport)
	}
```

And in `destination(for:)` use `Self.liveSession(for: host)` instead of `makeSession(for: host)`.

- [ ] **Step 3: Run full unit suite + iOS build**

Run: `make test`
Expected: macOS suite green, zero regressions, plus all `CatermMobileTerminalTests`.

Run: `make ios-build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/CatermMobile/MobileHostsView.swift Sources/CatermMobile/MobileCatermShell.swift
git commit -m "feat(mobile): route Connect to the live SSH terminal session"
```

### Task 11: Local sshd verification harness

**Files:**
- Create: `Scripts/dev-sshd.sh`

- [ ] **Step 1: Write the throwaway sshd script**

Create `Scripts/dev-sshd.sh`:

```bash
#!/bin/bash
# Throwaway OpenSSH server for mobile SSH terminal e2e. Listens on
# 127.0.0.1:2222 with a password account-free shell: it uses the CURRENT
# macOS user via an authorized_keys test keypair. Prints the host IP the
# iOS simulator should use. Ctrl-C to stop; everything lives under a temp
# dir and is deleted on exit.
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; echo "cleaned $WORK"' EXIT

ssh-keygen -q -t ed25519 -f "$WORK/host_ed25519" -N ''
ssh-keygen -q -t ed25519 -f "$WORK/id_ed25519" -N ''
cp "$WORK/id_ed25519.pub" "$WORK/authorized_keys"

cat > "$WORK/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $WORK/host_ed25519
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication yes
PermitRootLogin no
UsePAM no
StrictModes no
Subsystem sftp internal-sftp
EOF

echo "test private key: $WORK/id_ed25519"
echo "username: $(whoami)"
echo "endpoint for simulator: 127.0.0.1:2222 (simulator shares host loopback)"
echo "starting sshd (foreground)…"
/usr/sbin/sshd -D -f "$WORK/sshd_config" -e
```

```bash
chmod +x Scripts/dev-sshd.sh
```

- [ ] **Step 2: Smoke the harness locally (manual, documented)**

Run in a separate shell: `./Scripts/dev-sshd.sh`
Then verify from the Mac: `ssh -p 2222 -i <printed key> -o StrictHostKeyChecking=no $(whoami)@127.0.0.1 'echo HARNESS_OK'`
Expected: prints `HARNESS_OK`. Stop the harness with Ctrl-C.

- [ ] **Step 3: Commit**

```bash
git add Scripts/dev-sshd.sh
git commit -m "test(mobile): add throwaway local sshd harness"
```

### Task 12: Real-SSH end-to-end on the simulator

**Files:**
- Create: `Scripts/ios-ssh-e2e.sh`

- [ ] **Step 1: Write the e2e driver**

Create `Scripts/ios-ssh-e2e.sh`:

```bash
#!/bin/bash
# Real-SSH e2e: assumes Scripts/dev-sshd.sh is already running in another
# shell and that a host named "E2E" exists in the simulator app pointing
# at 127.0.0.1:2222 with the harness key/credential saved (set up once via
# the app UI driven by idb, or seeded). Builds, launches, types a marker
# command over the live SSH session, screenshots, and asserts the marker
# echo is visible.
set -euo pipefail
SIM="${IOS_SIM:?set IOS_SIM to the booted simulator UDID}"
MARKER="CATERM_SSH_OK_$RANDOM"
IDB() { python3 -c "import asyncio; asyncio.set_event_loop(asyncio.new_event_loop()); import sys; sys.argv=['idb']+sys.argv[1:]; from idb.cli.main import main; main()" "$@"; }

make ios-build
xcrun simctl install "$SIM" build/Debug-iphonesimulator/Caterm.app
xcrun simctl launch "$SIM" app.caterm.mobile
sleep 4

# Navigate: Hosts tab -> first host -> Connect. Coordinates are for
# iPhone 17 Pro (402x874 pt); adjust if the device differs.
IDB ui tap --udid "$SIM" 200 250          # first host row
sleep 1
IDB ui tap --udid "$SIM" 200 300          # Connect button
sleep 5                                     # connect + auth + shell
IDB ui text --udid "$SIM" "echo $MARKER"
IDB ui key --udid "$SIM" 40                # Return (HID usage 0x28)
sleep 2
xcrun simctl io "$SIM" screenshot /tmp/ios-ssh-e2e.png

# OCR-free assertion: pull the SwiftTerm buffer is not exposed, so assert
# on the screenshot via the macOS `vision` text recognizer.
python3 - "$MARKER" <<'PY'
import sys, subprocess, json, Quartz, Vision
marker = sys.argv[1]
img = Quartz.CIImage.imageWithContentsOfURL_(Quartz.NSURL.fileURLWithPath_("/tmp/ios-ssh-e2e.png"))
h = Vision.VNImageRequestHandler.alloc().initWithCIImage_options_(img, None)
req = Vision.VNRecognizeTextRequest.alloc().init()
req.setRecognitionLevel_(1)
h.performRequests_error_([req], None)
texts = []
for r in req.results():
    texts.append(r.topCandidates_(1)[0].string())
joined = "\n".join(texts)
print(joined)
sys.exit(0 if marker in joined else 1)
PY
echo "E2E PASS: marker $MARKER rendered over real SSH"
```

```bash
chmod +x Scripts/ios-ssh-e2e.sh
```

> NOTE: `idb ui text` / `idb ui key` send hardware-keyboard events to the
> focused responder. If SwiftTerm's `TerminalView` is not first responder,
> tap the terminal area first (`IDB ui tap --udid "$SIM" 200 400`). If
> `Vision`/`Quartz` Python bindings are unavailable, fall back to manual
> visual confirmation by reading `/tmp/ios-ssh-e2e.png`.

- [ ] **Step 2: Run the full real-SSH e2e**

In shell A: `./Scripts/dev-sshd.sh`
In shell B: one-time, drive the app via idb (or seed) to create host "E2E"
→ `127.0.0.1`, port `2222`, username `$(whoami)`, credential `keyFile`
pointing at the harness `id_ed25519` (or password). Then:

```bash
IOS_SIM=<booted-udid> ./Scripts/ios-ssh-e2e.sh
```

Expected: `E2E PASS: marker … rendered over real SSH`. Inspect
`/tmp/ios-ssh-e2e.png` to confirm the Termius-style screen + key bar.

- [ ] **Step 3: Capture proof + commit**

```bash
git add Scripts/ios-ssh-e2e.sh
git commit -m "test(mobile): add real-SSH simulator e2e driver"
```

### Task 13: Final audit

- [ ] **Step 1: Full suite**

Run: `make test`
Expected: macOS green, all `CatermMobileTerminalTests` green, zero regressions.

- [ ] **Step 2: iOS build + run**

Run: `make run-ios`
Expected: app launches; connecting to a real host yields an interactive
shell with working key bar (Ctrl-C interrupts, arrows do history,
resize tracks rotation).

- [ ] **Step 3: Spec coverage check**

Confirm against `docs/superpowers/specs/2026-05-16-mobile-ssh-terminal-design.md`:
SSHAuthPlan ✓, MobileKnownHostsStore ✓, TerminalKeyBar ✓,
TerminalResize ✓, SSHTerminalSession ✓, NIOSSHTransport ✓,
SwiftTermBridge ✓, MobileTerminalSessionView ✓, Connect wiring ✓,
real-SSH verification ✓, macOS untouched ✓.

- [ ] **Step 4: Commit any audit-only fixes separately.**
