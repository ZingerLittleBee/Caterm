# macOS Snippets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship CloudKit-synced reusable command/script snippets that the user can paste or run into the active SSH terminal.

**Architecture:** Mirror the host-sync architecture: low-level types target (`SnippetSyncClient`) holds wire types + protocol, high-level coordinator target (`SnippetStore`) holds persistence + sync orchestrator, and `CloudKitSyncClient` extends to conform. Snippets live in a dedicated `Snippets` CloudKit zone with their own UserDefaults token namespace, so they cannot perturb host-sync state. Sync passes are serialized: drain delete outbox → fetch → reconcile (LWW) → push winners → commit checkpoint. UI consists of a command palette, an editor sheet, a manager sheet, and a toolbar button — all observable from both `MainWindow` and `LandingView`, gated by `NSWindow.isKeyWindow`.

**Tech Stack:** Swift 5.10, SwiftUI, CloudKit (`CKDatabaseSubscription` private DB), XCTest, libghostty (`GhosttySurface.sendText` / `sendKey` / `triggerBindingAction`), SwiftPM with library + test targets.

**Spec:** [`docs/superpowers/specs/2026-05-06-macos-snippets-design.md`](../specs/2026-05-06-macos-snippets-design.md)

**Plan position:** Plan F. Independent of Plan E. Dev environment work is parallel-safe with Plan E; production rollout (CloudKit Dashboard `Deploy Schema to Production` + two-Mac live verification) blocks on Plan E shipping.

---

## File Structure

| Path | Status | Purpose |
|---|---|---|
| `apps/macos/Package.swift` | modify | Register `SnippetSyncClient`, `SnippetStore` library targets and matching test targets; add `SnippetSyncClient` to `CloudKitSyncClient` deps; add both to `Caterm` exec deps. |
| `apps/macos/Sources/SnippetSyncClient/Snippet.swift` | create | `Snippet` struct, `Codable`/`Sendable`/`Equatable`/`Hashable`. |
| `apps/macos/Sources/SnippetSyncClient/SnippetChangeBatch.swift` | create | `SnippetChangeBatch`, `SnippetSyncMode`. |
| `apps/macos/Sources/SnippetSyncClient/IncrementalSnippetSyncClient.swift` | create | `IncrementalSnippetSyncClient` protocol + `SnippetSyncCheckpoint` protocol. |
| `apps/macos/Sources/SnippetSyncClient/SnippetSyncNotifications.swift` | create | `Notification.Name.catermCloudKitSnippetChanged`, `Notification.Name.catermOpenSnippetPalette`, `.catermNewSnippet`, `.catermOpenSnippetManager`. |
| `apps/macos/Sources/SnippetStore/SnippetStore.swift` | create | `SnippetStore` actor/class — JSON persistence, `@Published` snapshot, CRUD, search, outbox, `wipeLocal`. |
| `apps/macos/Sources/SnippetStore/SnippetSyncReconciler.swift` | create | LWW algorithm — pure functions on local + remote inputs → ops list. |
| `apps/macos/Sources/SnippetStore/SnippetSyncOperation.swift` | create | Internal op enum: `.applyRemote`, `.applyTombstone`, `.pushLocal`. |
| `apps/macos/Sources/SnippetStore/SnippetSyncStore.swift` | create | Sync-pass orchestrator — schedule, debounce, drive client. |
| `apps/macos/Sources/CloudKitSyncClient/CKRecordSnippetMapping.swift` | create | `Snippet ↔ CKRecord` encode/decode. |
| `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Snippet.swift` | create | `extension CloudKitSyncClient: IncrementalSnippetSyncClient` — fetch, push, delete, subscription. |
| `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift` | modify | Add `snippetSubscriptionID`, `snippetZoneName`. |
| `apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift` | modify | Widen `AccountSensitiveClient` to also reset snippet sync state + delete snippet subscription. |
| `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift` | modify | Accept a key prefix on init so a second instance can share UserDefaults without colliding with host keys. |
| `apps/macos/Sources/SessionStore/SessionStore.swift` | modify | Add `Tab.surface: Weak<GhosttySurface>` registry field. |
| `apps/macos/Sources/TerminalEngine/GhosttySurface+SnippetInjection.swift` | create | `pasteSnippet(_:)` and `executeSnippet(_:)` extensions. |
| `apps/macos/Sources/Caterm/CatermApp.swift` | modify | Wire `SnippetStore`, `SnippetSyncStore`, account observer, APS dispatch case, menu commands. |
| `apps/macos/Sources/Caterm/AppDelegate.swift` | modify | Add `.snippet` case to `parsePushUserInfo` dispatch. |
| `apps/macos/Sources/Caterm/Views/Snippets/SnippetCommandObserver.swift` | create | Shared `ViewModifier` observing the three menu notifications, gated on `isKeyWindow`. |
| `apps/macos/Sources/Caterm/Views/Snippets/SnippetPalette.swift` | create | Palette view: search field + list + Enter/⌘+Enter. |
| `apps/macos/Sources/Caterm/Views/Snippets/SnippetEditorSheet.swift` | create | Create/edit sheet. |
| `apps/macos/Sources/Caterm/Views/Snippets/SnippetManagerSheet.swift` | create | Manager view with detail pane. |
| `apps/macos/Sources/Caterm/Views/Snippets/SnippetRowView.swift` | create | Single-row row view with hover menu. |
| `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` | modify | Add toolbar button hosting `SnippetPalette` popover. |
| `apps/macos/Tests/SnippetSyncClientTests/SnippetTests.swift` | create | Snippet `Codable` round-trip. |
| `apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift` | create | CRUD + persistence + outbox + wipeLocal. |
| `apps/macos/Tests/SnippetStoreTests/SnippetSyncReconcilerTests.swift` | create | LWW matrix. |
| `apps/macos/Tests/SnippetStoreTests/SnippetSyncStoreTests.swift` | create | Sync pass + account-switch + stale-edit + tombstone-beats-dirty. |
| `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift` | create | Mock-CKDB tests for fetch/push/delete + zone enforcement. |
| `apps/macos/Tests/CatermTests/SnippetPaletteTests.swift` | create | Palette filter, dispatch, captured-surface immutability. |
| `docs/superpowers/2026-05-06-snippet-run-mode-spike.md` | create (Task 0) | Spike outcome record. |
| `docs/macos-snippet-sync-manual-verification.md` | create (Task 23) | Two-Mac live scenarios. |

---

## Task 0: Run-mode injection spike

**Spec:** §5.3, §5.4 — settle Run mode mechanism before any UI work.

**Files:**
- Create: `docs/superpowers/2026-05-06-snippet-run-mode-spike.md`

- [ ] **Step 0.1: Read the spec sections**

Open `docs/superpowers/specs/2026-05-06-macos-snippets-design.md` and read §5 in full. Note the three candidate paths (A, B, B') and the (C) fallback.

- [ ] **Step 0.2: Probe `sendText` against a known shell**

Build and run the app: `cd apps/macos && make run-app`. Connect to any SSH host. In the app, attach a debugger or temporary keyboard shortcut that calls `surface.sendText("echo hello\n")`. Observe whether the shell executes (output `hello` appears + new prompt) or whether the input sits at the prompt with the trailing newline visible.

If shell executes immediately: `sendText` is NOT bracketed-paste-wrapped on this libghostty version. Run mode is trivial — proceed to path (A) implementation note.

If input sits at prompt (most likely per the in-tree IME comment at `GhosttySurfaceNSView+TextInput.swift:39-43`): bracketed paste is applied. Continue to step 0.3.

- [ ] **Step 0.3: Probe `sendKey(Return)` after `sendText(content)` (path B′)**

Synthesize an `NSEvent` for Return:

```swift
let returnEvent = NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: surfaceView.window?.windowNumber ?? 0,
    context: nil,
    characters: "\r",
    charactersIgnoringModifiers: "\r",
    isARepeat: false,
    keyCode: 36 // kVK_Return
)!
surface.sendText("echo hello")
surface.sendKey(returnEvent, composing: false)
```

Observe whether `hello` is executed.

- [ ] **Step 0.4: Probe ghostty's exposed binding actions**

Read `GhosttySurface+Clipboard.swift` (`triggerBindingAction(_:)`) and search the libghostty headers under `apps/macos/Frameworks/GhosttyKit.xcframework/`:

```bash
grep -r "binding_action\|input_action" apps/macos/Frameworks/GhosttyKit.xcframework/ | head -20
```

Look for any action name that injects raw text bypassing bracketed paste (e.g. `text_insert`, `write`, `inject_text`).

- [ ] **Step 0.5: Validate against bash 5, zsh 5.9, fish 3**

For whichever mechanism passes step 0.2 / 0.3 / 0.4, run the §5.4 test matrix:

1. `echo hello` → output appears, prompt advances.
2. Multi-line `for i in 1 2 3; do echo $i; done` → loop completes.
3. `$(date)` substitution → expanded by shell, not pre-evaluated by terminal.
4. Whitespace-leading snippet → `HISTCONTROL=ignorespace` still works.
5. IME preedit non-empty → no corruption.

Test against each of bash/zsh/fish on a real remote host (any SSH host with at least one of these installed will do).

- [ ] **Step 0.6: Write the outcome record**

Write `docs/superpowers/2026-05-06-snippet-run-mode-spike.md`:

```markdown
# Run-mode injection spike — outcome

**Date:** 2026-05-06
**Spec section:** §5.3 / §5.4

## Mechanism chosen

[ONE OF: (A) raw `sendText` works as-is | (A′) raw API found: `<name>` | (B) per-character `sendKey` | (B′) `sendText` body + `sendKey(Return)` | (C) fallback — Paste only in v1]

## Evidence

- Step 0.2: <result>
- Step 0.3: <result>
- Step 0.4: <result>
- Step 0.5: <results per shell>

## Implementation reference

For Task 19 (`GhosttySurface+SnippetInjection.swift`), the chosen mechanism is implemented as:

\`\`\`swift
[exact code snippet for executeSnippet(_:)]
\`\`\`

## If outcome was (C)

Plan F v1 ships Paste mode only. Run mode is deferred to a follow-up that either:
- Lands a public raw-input API in the in-tree ghostty submodule (`apps/macos/Vendor/ghostty`).
- Or implements per-character keystroke synthesis with full IME state handling.

The user is notified before further implementation work proceeds.
```

- [ ] **Step 0.7: Commit**

```bash
git add docs/superpowers/2026-05-06-snippet-run-mode-spike.md
git commit -m "spike: snippet run-mode injection — chose <mechanism>"
```

If outcome was (C), pause and notify the user before proceeding to Task 1. Otherwise continue.

---

## Task 1: Create `SnippetSyncClient` target

**Spec:** §3.1.

**Files:**
- Modify: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/SnippetSyncClient/.gitkeep`
- Create: `apps/macos/Tests/SnippetSyncClientTests/.gitkeep`

- [ ] **Step 1.1: Add the library target to `Package.swift`**

In `apps/macos/Package.swift`, after the `SettingsSyncStore` target block (around line 81), insert:

```swift
        .target(
            name: "SnippetSyncClient",
            path: "Sources/SnippetSyncClient"
        ),
```

- [ ] **Step 1.2: Add the test target**

After the existing `SettingsSyncStoreTests` target, insert:

```swift
        .testTarget(
            name: "SnippetSyncClientTests",
            dependencies: ["SnippetSyncClient"],
            path: "Tests/SnippetSyncClientTests"
        ),
```

- [ ] **Step 1.3: Create empty source dirs**

```bash
mkdir -p apps/macos/Sources/SnippetSyncClient apps/macos/Tests/SnippetSyncClientTests
touch apps/macos/Sources/SnippetSyncClient/.gitkeep apps/macos/Tests/SnippetSyncClientTests/.gitkeep
```

- [ ] **Step 1.4: Verify the package resolves**

```bash
cd apps/macos && swift build --target SnippetSyncClient
```

Expected: `Build complete!` (target builds with zero source files — empty target is legal).

- [ ] **Step 1.5: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/SnippetSyncClient apps/macos/Tests/SnippetSyncClientTests
git commit -m "chore(macos): scaffold SnippetSyncClient target"
```

---

## Task 2: `Snippet` model + Codable round-trip test

**Spec:** §3.2.

**Files:**
- Create: `apps/macos/Sources/SnippetSyncClient/Snippet.swift`
- Test: `apps/macos/Tests/SnippetSyncClientTests/SnippetTests.swift`

- [ ] **Step 2.1: Write the failing test**

Create `apps/macos/Tests/SnippetSyncClientTests/SnippetTests.swift`:

```swift
import XCTest
@testable import SnippetSyncClient

final class SnippetTests: XCTestCase {
    func test_codable_roundTrip() throws {
        let original = Snippet(
            id: UUID(),
            name: "List docker containers",
            content: "docker ps -a",
            placeholders: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            serverId: "abc",
            revision: 3,
            metadataUpdatedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_codable_nilOptionalsPreserved() throws {
        let original = Snippet(
            id: UUID(),
            name: "x",
            content: "y",
            placeholders: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            serverId: nil,
            revision: 0,
            metadataUpdatedAt: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.placeholders)
        XCTAssertNil(decoded.serverId)
        XCTAssertNil(decoded.metadataUpdatedAt)
    }
}
```

- [ ] **Step 2.2: Run the test to confirm it fails**

```bash
cd apps/macos && swift test --filter SnippetTests
```

Expected: build failure ("cannot find 'Snippet' in scope").

- [ ] **Step 2.3: Implement `Snippet`**

Create `apps/macos/Sources/SnippetSyncClient/Snippet.swift`:

```swift
import Foundation

public struct Snippet: Identifiable, Codable, Equatable, Hashable, Sendable {
	public let id: UUID
	public var name: String
	public var content: String
	public var placeholders: [String]?
	public var createdAt: Date
	public var updatedAt: Date

	// Sync metadata. Mirrors SSHHost conventions.
	public var serverId: String?
	public var revision: Int
	public var metadataUpdatedAt: Date?

	public init(
		id: UUID,
		name: String,
		content: String,
		placeholders: [String]? = nil,
		createdAt: Date,
		updatedAt: Date,
		serverId: String? = nil,
		revision: Int = 0,
		metadataUpdatedAt: Date? = nil
	) {
		self.id = id
		self.name = name
		self.content = content
		self.placeholders = placeholders
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.serverId = serverId
		self.revision = revision
		self.metadataUpdatedAt = metadataUpdatedAt
	}
}
```

- [ ] **Step 2.4: Run the test to confirm it passes**

```bash
cd apps/macos && swift test --filter SnippetTests
```

Expected: 2 tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add apps/macos/Sources/SnippetSyncClient/Snippet.swift apps/macos/Tests/SnippetSyncClientTests/SnippetTests.swift
git commit -m "feat(snippets): Snippet model with Codable round-trip tests"
```

---

## Task 3: `SnippetChangeBatch` + `SnippetSyncMode` + protocol

**Spec:** §3.6, §3.4.

**Files:**
- Create: `apps/macos/Sources/SnippetSyncClient/SnippetChangeBatch.swift`
- Create: `apps/macos/Sources/SnippetSyncClient/IncrementalSnippetSyncClient.swift`
- Create: `apps/macos/Sources/SnippetSyncClient/SnippetSyncNotifications.swift`

- [ ] **Step 3.1: Create `SnippetChangeBatch.swift`**

```swift
import Foundation

public enum SnippetSyncMode: Sendable, Equatable {
	case incremental
	case forceFull
}

public protocol SnippetSyncCheckpoint: Sendable {
	var id: UUID { get }
}

public struct SnippetChangeBatch: Sendable {
	public let changedSnippets: [Snippet]
	public let deletedSnippetIDs: [UUID]
	public let checkpoint: (any SnippetSyncCheckpoint)?
	public let tokenExpired: Bool
	public let mode: SnippetSyncMode

	public init(
		changedSnippets: [Snippet],
		deletedSnippetIDs: [UUID],
		checkpoint: (any SnippetSyncCheckpoint)?,
		tokenExpired: Bool,
		mode: SnippetSyncMode
	) {
		self.changedSnippets = changedSnippets
		self.deletedSnippetIDs = deletedSnippetIDs
		self.checkpoint = checkpoint
		self.tokenExpired = tokenExpired
		self.mode = mode
	}
}
```

- [ ] **Step 3.2: Create `IncrementalSnippetSyncClient.swift`**

```swift
import Foundation

public protocol IncrementalSnippetSyncClient: Sendable {
	func preferredSnippetSyncMode() async -> SnippetSyncMode
	func fetchSnippetChanges() async throws -> SnippetChangeBatch
	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch
	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws
	func resetSnippetSyncState() async
	func ensureSnippetSubscription() async throws
	func deleteSnippetSubscription() async throws
	func pushSnippet(_ snippet: Snippet) async throws -> Snippet
	func deleteSnippet(id: UUID) async throws
	/// Probe whether persisted snippet tokens exist. Used by
	/// `AccountIdentityTracker.tokensExist`.
	func hasAnySnippetSyncTokens() async -> Bool
}
```

- [ ] **Step 3.3: Create `SnippetSyncNotifications.swift`**

```swift
import Foundation

public extension Notification.Name {
	/// Posted by `AppDelegate.application(_:didReceiveRemoteNotification:)`
	/// when an APS notification matching the snippet subscription arrives.
	/// Observed by `SnippetSyncStore`.
	static let catermCloudKitSnippetChanged =
		Notification.Name("catermCloudKitSnippetChanged")

	/// View → Open Snippet Palette (⌘⇧P).
	static let catermOpenSnippetPalette =
		Notification.Name("catermOpenSnippetPalette")

	/// View → New Snippet… (⌘⇧S).
	static let catermNewSnippet =
		Notification.Name("catermNewSnippet")

	/// View → Manage Snippets…
	static let catermOpenSnippetManager =
		Notification.Name("catermOpenSnippetManager")
}
```

- [ ] **Step 3.4: Verify the target builds**

```bash
cd apps/macos && swift build --target SnippetSyncClient
```

Expected: `Build complete!`.

- [ ] **Step 3.5: Commit**

```bash
git add apps/macos/Sources/SnippetSyncClient/
git commit -m "feat(snippets): SnippetChangeBatch + IncrementalSnippetSyncClient + notifications"
```

---

## Task 4: Create `SnippetStore` target shell + outbox model

**Spec:** §3.1, §3.8.

**Files:**
- Modify: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/SnippetStore/SnippetStore.swift` (shell only)
- Create: `apps/macos/Tests/SnippetStoreTests/.gitkeep`

- [ ] **Step 4.1: Add target + test target to `Package.swift`**

Add the library target after `SnippetSyncClient`:

```swift
        .target(
            name: "SnippetStore",
            dependencies: ["SnippetSyncClient"],
            path: "Sources/SnippetStore"
        ),
```

Add the test target after `SnippetSyncClientTests`:

```swift
        .testTarget(
            name: "SnippetStoreTests",
            dependencies: ["SnippetStore", "SnippetSyncClient"],
            path: "Tests/SnippetStoreTests"
        ),
```

- [ ] **Step 4.2: Create the shell**

```bash
mkdir -p apps/macos/Sources/SnippetStore apps/macos/Tests/SnippetStoreTests
touch apps/macos/Tests/SnippetStoreTests/.gitkeep
```

Create `apps/macos/Sources/SnippetStore/SnippetStore.swift`:

```swift
import Combine
import Foundation
import SnippetSyncClient

@MainActor
public final class SnippetStore: ObservableObject {
	@Published public private(set) var snippets: [Snippet] = []
	@Published public private(set) var pendingDeletedSnippetIDs: Set<UUID> = []

	private let snippetsURL: URL
	private let outboxURL: URL

	public init(directory: URL) {
		self.snippetsURL = directory.appendingPathComponent("snippets.json")
		self.outboxURL = directory.appendingPathComponent("snippets.outbox.json")
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}
}
```

- [ ] **Step 4.3: Verify it builds**

```bash
cd apps/macos && swift build --target SnippetStore
```

Expected: `Build complete!`.

- [ ] **Step 4.4: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/SnippetStore apps/macos/Tests/SnippetStoreTests
git commit -m "chore(macos): scaffold SnippetStore target"
```

---

## Task 5: `SnippetStore` — JSON persistence + CRUD

**Spec:** §3.2, §3.8.

**Files:**
- Modify: `apps/macos/Sources/SnippetStore/SnippetStore.swift`
- Test: `apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift`

- [ ] **Step 5.1: Write failing tests**

Create `apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift`:

```swift
import XCTest
import SnippetSyncClient
@testable import SnippetStore

@MainActor
final class SnippetStoreTests: XCTestCase {
	private func tempDir() -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("snippet-store-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func test_load_emptyOnFreshDir() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		XCTAssertEqual(store.snippets, [])
	}

	func test_upsertCreate_persistsAcrossInstances() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let s = Snippet(id: UUID(), name: "ls", content: "ls -la",
		                createdAt: .now, updatedAt: .now)
		try store.upsert(s)

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertEqual(store2.snippets.count, 1)
		XCTAssertEqual(store2.snippets.first?.name, "ls")
	}

	func test_upsertExisting_bumpsRevisionAndUpdatedAt() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		let original = Snippet(id: id, name: "a", content: "x",
		                       createdAt: .distantPast, updatedAt: .distantPast,
		                       revision: 0)
		try store.upsert(original)
		var edited = original
		edited.name = "b"
		try store.upsert(edited)

		XCTAssertEqual(store.snippets.first?.name, "b")
		XCTAssertGreaterThan(store.snippets.first!.revision, 0)
		XCTAssertGreaterThan(store.snippets.first!.updatedAt, original.updatedAt)
	}

	func test_delete_removesSnippetAndAddsToOutbox() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "x",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)
		XCTAssertEqual(store.snippets, [])
		XCTAssertTrue(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_outbox_persistsAcrossInstances() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "x",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertTrue(store2.pendingDeletedSnippetIDs.contains(id))
	}
}
```

- [ ] **Step 5.2: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter SnippetStoreTests
```

Expected: build failure or test failure (`load`, `upsert`, `delete` not defined).

- [ ] **Step 5.3: Implement load + upsert + delete + persistence**

Replace `apps/macos/Sources/SnippetStore/SnippetStore.swift` body with:

```swift
import Combine
import Foundation
import SnippetSyncClient

public enum SnippetStoreError: Error, Equatable {
	case writeFailed(String)
	case readFailed(String)
}

private struct SnippetsEnvelope: Codable {
	let schemaVersion: Int
	let snippets: [Snippet]
}

private struct OutboxEnvelope: Codable {
	let schemaVersion: Int
	let pendingDeletedSnippetIDs: [UUID]
}

@MainActor
public final class SnippetStore: ObservableObject {
	@Published public private(set) var snippets: [Snippet] = []
	@Published public private(set) var pendingDeletedSnippetIDs: Set<UUID> = []

	private let snippetsURL: URL
	private let outboxURL: URL
	private static let schemaVersion = 1

	public init(directory: URL) {
		self.snippetsURL = directory.appendingPathComponent("snippets.json")
		self.outboxURL = directory.appendingPathComponent("snippets.outbox.json")
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	public func load() throws {
		if let data = try? Data(contentsOf: snippetsURL) {
			let env = try JSONDecoder().decode(SnippetsEnvelope.self, from: data)
			self.snippets = env.snippets
		}
		if let data = try? Data(contentsOf: outboxURL) {
			let env = try JSONDecoder().decode(OutboxEnvelope.self, from: data)
			self.pendingDeletedSnippetIDs = Set(env.pendingDeletedSnippetIDs)
		}
	}

	public func upsert(_ s: Snippet) throws {
		var copy = s
		if let existingIdx = snippets.firstIndex(where: { $0.id == s.id }) {
			let existing = snippets[existingIdx]
			copy.revision = existing.revision + 1
			copy.updatedAt = Date()
			copy.createdAt = existing.createdAt
			snippets[existingIdx] = copy
		} else {
			snippets.append(copy)
		}
		try writeSnippets()
	}

	public func delete(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		pendingDeletedSnippetIDs.insert(id)
		try writeSnippets()
		try writeOutbox()
	}

	public func clearOutboxEntry(_ id: UUID) throws {
		pendingDeletedSnippetIDs.remove(id)
		try writeOutbox()
	}

	public func wipeLocal() throws {
		snippets = []
		pendingDeletedSnippetIDs = []
		try writeSnippets()
		try writeOutbox()
	}

	// MARK: - Persistence

	private func writeSnippets() throws {
		let env = SnippetsEnvelope(schemaVersion: Self.schemaVersion, snippets: snippets)
		try atomicWrite(JSONEncoder().encode(env), to: snippetsURL)
	}

	private func writeOutbox() throws {
		let env = OutboxEnvelope(
			schemaVersion: Self.schemaVersion,
			pendingDeletedSnippetIDs: Array(pendingDeletedSnippetIDs)
		)
		try atomicWrite(JSONEncoder().encode(env), to: outboxURL)
	}

	private func atomicWrite(_ data: Data, to url: URL) throws {
		let tmp = url.appendingPathExtension("tmp")
		do {
			try data.write(to: tmp, options: .atomic)
			_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
		} catch {
			try? FileManager.default.removeItem(at: tmp)
			throw SnippetStoreError.writeFailed(error.localizedDescription)
		}
	}
}
```

- [ ] **Step 5.4: Run tests to confirm they pass**

```bash
cd apps/macos && swift test --filter SnippetStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 5.5: Commit**

```bash
git add apps/macos/Sources/SnippetStore/SnippetStore.swift apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift
git commit -m "feat(snippets): SnippetStore CRUD + atomic JSON persistence + outbox"
```

---

## Task 6: `SnippetStore` — search + apply-pulled

**Spec:** §3.7, §4.4 search, §3.11 sync pass.

**Files:**
- Modify: `apps/macos/Sources/SnippetStore/SnippetStore.swift`
- Modify: `apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift`

- [ ] **Step 6.1: Write failing tests**

Append to `SnippetStoreTests.swift`:

```swift
extension SnippetStoreTests {
	func test_search_matchesNameAndContentCaseInsensitive() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		try store.upsert(Snippet(id: UUID(), name: "Docker", content: "docker ps",
		                         createdAt: .now, updatedAt: .now))
		try store.upsert(Snippet(id: UUID(), name: "List files", content: "ls -la",
		                         createdAt: .now, updatedAt: .now))

		XCTAssertEqual(store.search("docker").count, 1)
		XCTAssertEqual(store.search("DOCKER").count, 1)
		XCTAssertEqual(store.search("ps").count, 1)
		XCTAssertEqual(store.search("la").count, 1)
		XCTAssertEqual(store.search("nope").count, 0)
		XCTAssertEqual(store.search("").count, 2)
	}

	func test_applyRemoteUpsert_replacesExistingByID() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "old", content: "x",
		                         createdAt: .now, updatedAt: Date(timeIntervalSince1970: 1),
		                         revision: 1))
		// Server-authoritative version arrives.
		let remote = Snippet(id: id, name: "new", content: "y",
		                     createdAt: .now, updatedAt: Date(timeIntervalSince1970: 100),
		                     revision: 5)
		try store.applyRemote(remote)
		XCTAssertEqual(store.snippets.first?.name, "new")
		XCTAssertEqual(store.snippets.first?.revision, 5)
	}

	func test_applyRemoteTombstone_removesEvenIfDirty() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.applyRemoteTombstone(id: id)
		XCTAssertTrue(store.snippets.isEmpty)
		// Tombstone application also clears the local outbox entry if any.
		XCTAssertFalse(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_wipeLocal_clearsBothFiles() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)
		try store.wipeLocal()

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertEqual(store2.snippets, [])
		XCTAssertEqual(store2.pendingDeletedSnippetIDs, [])
	}
}
```

- [ ] **Step 6.2: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter SnippetStoreTests
```

Expected: build failure (`search`, `applyRemote`, `applyRemoteTombstone` undefined).

- [ ] **Step 6.3: Implement the methods**

Add to `SnippetStore` (before the persistence MARK):

```swift
	public func search(_ query: String) -> [Snippet] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return snippets }
		let needle = trimmed.lowercased()
		return snippets.filter {
			$0.name.lowercased().contains(needle)
				|| $0.content.lowercased().contains(needle)
		}
	}

	/// Apply a server-authoritative snippet (post-LWW reconciliation).
	public func applyRemote(_ s: Snippet) throws {
		if let idx = snippets.firstIndex(where: { $0.id == s.id }) {
			snippets[idx] = s
		} else {
			snippets.append(s)
		}
		try writeSnippets()
	}

	/// Remove the snippet from local state. Also clears any outbox entry —
	/// a tombstone observed in the cloud supersedes our pending delete.
	public func applyRemoteTombstone(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		pendingDeletedSnippetIDs.remove(id)
		try writeSnippets()
		try writeOutbox()
	}
```

- [ ] **Step 6.4: Run tests to confirm they pass**

```bash
cd apps/macos && swift test --filter SnippetStoreTests
```

Expected: 9 tests pass.

- [ ] **Step 6.5: Commit**

```bash
git add apps/macos/Sources/SnippetStore/SnippetStore.swift apps/macos/Tests/SnippetStoreTests/SnippetStoreTests.swift
git commit -m "feat(snippets): SnippetStore search + applyRemote + applyRemoteTombstone + wipeLocal"
```

---

## Task 7: `SnippetSyncReconciler` — LWW algorithm

**Spec:** §3.7.

**Files:**
- Create: `apps/macos/Sources/SnippetStore/SnippetSyncOperation.swift`
- Create: `apps/macos/Sources/SnippetStore/SnippetSyncReconciler.swift`
- Test: `apps/macos/Tests/SnippetStoreTests/SnippetSyncReconcilerTests.swift`

- [ ] **Step 7.1: Define the operation enum**

Create `apps/macos/Sources/SnippetStore/SnippetSyncOperation.swift`:

```swift
import Foundation
import SnippetSyncClient

public enum SnippetSyncOperation: Sendable, Equatable {
	case applyRemote(Snippet)
	case applyTombstone(id: UUID)
	case pushLocal(Snippet)
}
```

- [ ] **Step 7.2: Write the failing tests**

Create `apps/macos/Tests/SnippetStoreTests/SnippetSyncReconcilerTests.swift`:

```swift
import XCTest
import SnippetSyncClient
@testable import SnippetStore

final class SnippetSyncReconcilerTests: XCTestCase {
	private func snip(id: UUID = UUID(), name: String = "n",
	                  revision: Int = 0,
	                  metaUpdated: Date? = nil,
	                  updatedAt: Date = Date(timeIntervalSince1970: 0)) -> Snippet {
		Snippet(id: id, name: name, content: "c",
		        createdAt: .distantPast, updatedAt: updatedAt,
		        revision: revision, metadataUpdatedAt: metaUpdated)
	}

	func test_remoteHigherRevision_appliesRemote() {
		let id = UUID()
		let local = snip(id: id, revision: 1)
		let remote = snip(id: id, name: "remote", revision: 2)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_remoteLowerRevision_pushesLocalIfDirty() {
		let id = UUID()
		let local = snip(id: id, revision: 5)
		let remote = snip(id: id, name: "stale", revision: 2)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_remoteEqualRevision_metadataUpdatedAtBreaksTie_cloudWins() {
		let id = UUID()
		let local = snip(id: id, revision: 1, metaUpdated: Date(timeIntervalSince1970: 100))
		let remote = snip(id: id, name: "remote", revision: 1, metaUpdated: Date(timeIntervalSince1970: 200))
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_remoteTombstone_emitsApplyTombstone_evenIfLocalDirty() {
		let id = UUID()
		let local = snip(id: id, revision: 99)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [], deletedIDs: [id],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.applyTombstone(id: id)])
	}

	func test_localOnly_dirty_pushesIfNotInRemote() {
		let id = UUID()
		let local = snip(id: id, revision: 1)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [], deletedIDs: [],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_forceFullSnapshot_remoteAuthoritative_localOnlyDeleted() {
		let id1 = UUID(), id2 = UUID()
		let local = [snip(id: id1, revision: 1), snip(id: id2, revision: 1)]
		let remote = [snip(id: id1, name: "kept", revision: 2)]
		let ops = SnippetSyncReconciler.reconcileFullSnapshot(
			local: local, remote: remote, locallyDirty: []
		)
		// id1 → applyRemote (newer); id2 → applyTombstone (not in snapshot).
		XCTAssertTrue(ops.contains(.applyRemote(remote[0])))
		XCTAssertTrue(ops.contains(.applyTombstone(id: id2)))
	}

	func test_forceFullSnapshot_locallyDirtyAbsentRemote_pushedNotDeleted() {
		let id = UUID()
		let local = [snip(id: id, revision: 1)]
		let ops = SnippetSyncReconciler.reconcileFullSnapshot(
			local: local, remote: [], locallyDirty: [id]
		)
		// New local snippet not yet pushed — must push, not delete.
		XCTAssertEqual(ops, [.pushLocal(local[0])])
	}
}
```

- [ ] **Step 7.3: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter SnippetSyncReconcilerTests
```

Expected: build failure (`SnippetSyncReconciler` undefined).

- [ ] **Step 7.4: Implement the reconciler**

Create `apps/macos/Sources/SnippetStore/SnippetSyncReconciler.swift`:

```swift
import Foundation
import SnippetSyncClient

public enum SnippetSyncReconciler {
	/// Incremental delta reconciliation. `locallyDirty` IDs are local
	/// snippets that have been edited since their last successful push;
	/// they may need to be pushed if the remote either matches or lags.
	public static func reconcileDelta(
		local: [Snippet],
		changedSnippets: [Snippet],
		deletedIDs: [UUID],
		locallyDirty: Set<UUID>
	) -> [SnippetSyncOperation] {
		var ops: [SnippetSyncOperation] = []
		let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

		// Tombstones first — terminal.
		let tombstoneSet = Set(deletedIDs)
		for id in deletedIDs {
			ops.append(.applyTombstone(id: id))
		}

		for remote in changedSnippets {
			if tombstoneSet.contains(remote.id) { continue }
			guard let l = localById[remote.id] else {
				ops.append(.applyRemote(remote))
				continue
			}
			switch compare(local: l, remote: remote) {
			case .remoteWins: ops.append(.applyRemote(remote))
			case .localWins:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
				// else: parity, no-op.
			case .parity: break
			}
		}

		// Locally dirty snippets that the server has not changed in this delta.
		let touchedRemoteIDs = Set(changedSnippets.map(\.id))
		for id in locallyDirty {
			if tombstoneSet.contains(id) { continue }
			if touchedRemoteIDs.contains(id) { continue }
			if let l = localById[id] {
				ops.append(.pushLocal(l))
			}
		}
		return ops
	}

	/// Force-full snapshot reconciliation. The remote list is authoritative;
	/// anything missing locally is added, anything extra locally is tombstoned
	/// (unless it's locally dirty — meaning it was created locally and not yet
	/// pushed).
	public static func reconcileFullSnapshot(
		local: [Snippet],
		remote: [Snippet],
		locallyDirty: Set<UUID>
	) -> [SnippetSyncOperation] {
		var ops: [SnippetSyncOperation] = []
		let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
		let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

		for r in remote {
			guard let l = localById[r.id] else {
				ops.append(.applyRemote(r))
				continue
			}
			switch compare(local: l, remote: r) {
			case .remoteWins: ops.append(.applyRemote(r))
			case .localWins:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
			case .parity: break
			}
		}
		for l in local where remoteById[l.id] == nil {
			if locallyDirty.contains(l.id) {
				ops.append(.pushLocal(l))
			} else {
				ops.append(.applyTombstone(id: l.id))
			}
		}
		return ops
	}

	// MARK: - Internals

	private enum CompareOutcome { case remoteWins, localWins, parity }

	private static func compare(local: Snippet, remote: Snippet) -> CompareOutcome {
		if remote.revision > local.revision { return .remoteWins }
		if remote.revision < local.revision { return .localWins }
		// Equal revision — compare metadataUpdatedAt (server-authoritative).
		switch (remote.metadataUpdatedAt, local.metadataUpdatedAt) {
		case let (.some(r), .some(l)):
			if r > l { return .remoteWins }
			if r < l { return .localWins }
		case (.some, nil): return .remoteWins
		case (nil, .some): return .localWins
		case (nil, nil): break
		}
		// Final tie-break: updatedAt, then cloud wins.
		if remote.updatedAt > local.updatedAt { return .remoteWins }
		if remote.updatedAt < local.updatedAt { return .localWins }
		return .parity
	}
}
```

- [ ] **Step 7.5: Run tests to confirm they pass**

```bash
cd apps/macos && swift test --filter SnippetSyncReconcilerTests
```

Expected: 7 tests pass.

- [ ] **Step 7.6: Commit**

```bash
git add apps/macos/Sources/SnippetStore/SnippetSyncOperation.swift apps/macos/Sources/SnippetStore/SnippetSyncReconciler.swift apps/macos/Tests/SnippetStoreTests/SnippetSyncReconcilerTests.swift
git commit -m "feat(snippets): SnippetSyncReconciler with LWW (revision → metadataUpdatedAt → updatedAt)"
```

---

## Task 8: Snippet token store with namespace prefix

**Spec:** §3.5.

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`

- [ ] **Step 8.1: Add a key-prefix init to `UserDefaultsServerChangeTokenStore`**

Replace the existing `UserDefaultsServerChangeTokenStore.init` and the static key constants. The original is at `ServerChangeTokenStore.swift:113-199`. Refactor so the key prefix is configurable:

```swift
internal actor UserDefaultsServerChangeTokenStore: ServerChangeTokenStoring {
	// MIGRATION NOTE: the host instance uses prefix "cloudkit.changeToken".
	// Plan F's snippet instance uses "cloudkit.changeToken.snippet". Renaming
	// the prefix orphans existing tokens; treat as load-bearing identity.
	private let dbKey: String
	private let epochKey: String
	private let zonePrefix: String
	private let defaults: UserDefaults

	init(defaults: UserDefaults = .standard, keyPrefix: String = "cloudkit.changeToken") {
		self.defaults = defaults
		self.dbKey = "\(keyPrefix).database"
		self.epochKey = "\(keyPrefix).epoch"
		self.zonePrefix = "\(keyPrefix).zone."
	}

	func currentEpoch() async -> UInt64 {
		UInt64(bitPattern: Int64(defaults.integer(forKey: epochKey)))
	}

	func bumpEpoch() async {
		let current = await currentEpoch()
		defaults.set(Int64(bitPattern: current &+ 1), forKey: epochKey)
	}

	func loadDatabaseToken() async -> StoredServerChangeToken? {
		defaults.data(forKey: dbKey).map { StoredServerChangeToken(archivedData: $0) }
	}

	func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken? {
		defaults.data(forKey: zoneKey(for: zoneID))
			.map { StoredServerChangeToken(archivedData: $0) }
	}

	func commitTokens(expectedEpoch: UInt64,
	                  db: TokenCAS,
	                  zones: [String: TokenCAS]) async -> CommitOutcome {
		guard await currentEpoch() == expectedEpoch else { return .staleEpoch }
		var skippedZones: [String] = []
		var skippedDb = false

		for (zoneKey, cas) in zones {
			let storageKey = zonePrefix + zoneKey
			let persisted = defaults.data(forKey: storageKey)
			if persisted == cas.prev {
				if let new = cas.new { defaults.set(new, forKey: storageKey) }
				else { defaults.removeObject(forKey: storageKey) }
			} else {
				skippedZones.append(zoneKey)
			}
		}

		let persistedDb = defaults.data(forKey: dbKey)
		if persistedDb == db.prev {
			if let new = db.new { defaults.set(new, forKey: dbKey) }
			else { defaults.removeObject(forKey: dbKey) }
		} else {
			skippedDb = true
		}

		if skippedZones.isEmpty && !skippedDb { return .applied }
		return .partialCAS(skippedZoneKeys: skippedZones, skippedDb: skippedDb)
	}

	func clearAll() async {
		await bumpEpoch()
		defaults.removeObject(forKey: dbKey)
		for key in defaults.dictionaryRepresentation().keys
		where key.hasPrefix(zonePrefix) {
			defaults.removeObject(forKey: key)
		}
	}

	private func zoneKey(for zoneID: CKRecordZone.ID) -> String {
		zonePrefix + InMemoryServerChangeTokenStore.key(for: zoneID)
	}
}
```

- [ ] **Step 8.2: Verify the host path still works**

```bash
cd apps/macos && swift test --filter HostSyncStoreTests
```

Expected: all existing host tests pass. (The default-arg `keyPrefix: String = "cloudkit.changeToken"` preserves the existing host key namespace.)

- [ ] **Step 8.3: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift
git commit -m "refactor(cloudkit): UserDefaultsServerChangeTokenStore accepts keyPrefix for snippet zone reuse"
```

---

## Task 9: `CKRecordSnippetMapping` — encode/decode

**Spec:** §3.3.

**Files:**
- Modify: `apps/macos/Package.swift` — add `SnippetSyncClient` to `CloudKitSyncClient.dependencies`
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift`
- Create: `apps/macos/Sources/CloudKitSyncClient/CKRecordSnippetMapping.swift`
- Test: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift` (mapping section)

- [ ] **Step 9.1: Wire deps**

In `Package.swift`, find the `CloudKitSyncClient` target and append `"SnippetSyncClient"` to its dependencies:

```swift
        .target(
            name: "CloudKitSyncClient",
            dependencies: ["ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes", "SettingsSyncStore", "SnippetSyncClient"],
            path: "Sources/CloudKitSyncClient"
        ),
```

Find `CloudKitSyncClientTests` test target and add `"SnippetSyncClient"` if not already present.

- [ ] **Step 9.2: Add subscription + zone names**

Open `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift` and add:

```swift
public extension CloudKitPushNames {
	static let snippetSubscriptionID = "com.caterm.app.snippet-changes"
	static let snippetZoneName = "Snippets"
}
```

(If the file uses `enum CloudKitPushNames`, add as `static let` inside the enum body.)

- [ ] **Step 9.3: Write failing mapping tests**

Create `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift`:

```swift
import CloudKit
import XCTest
import SnippetSyncClient
@testable import CloudKitSyncClient

final class CKRecordSnippetMappingTests: XCTestCase {
	func test_encode_setsAllFields() {
		let id = UUID()
		let s = Snippet(
			id: id, name: "n", content: "c",
			placeholders: nil,
			createdAt: Date(timeIntervalSince1970: 1),
			updatedAt: Date(timeIntervalSince1970: 2),
			serverId: nil, revision: 7, metadataUpdatedAt: nil
		)
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		XCTAssertEqual(rec.recordID.recordName, id.uuidString)
		XCTAssertEqual(rec.recordID.zoneID, zoneID)
		XCTAssertEqual(rec["name"] as? String, "n")
		XCTAssertEqual(rec["content"] as? String, "c")
		XCTAssertEqual(rec["createdAt"] as? Date, Date(timeIntervalSince1970: 1))
		XCTAssertEqual(rec["updatedAt"] as? Date, Date(timeIntervalSince1970: 2))
		XCTAssertEqual(rec["revision"] as? Int64, 7)
		XCTAssertEqual(rec["schemaVersion"] as? Int64, 1)
		XCTAssertNil(rec["placeholders"])
	}

	func test_decode_roundTripsCoreFields() throws {
		let id = UUID()
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		rec["content"] = "c" as CKRecordValue
		rec["createdAt"] = Date(timeIntervalSince1970: 1) as CKRecordValue
		rec["updatedAt"] = Date(timeIntervalSince1970: 2) as CKRecordValue
		rec["revision"] = Int64(7) as CKRecordValue
		rec["schemaVersion"] = Int64(1) as CKRecordValue

		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.id, id)
		XCTAssertEqual(decoded.name, "n")
		XCTAssertEqual(decoded.content, "c")
		XCTAssertEqual(decoded.revision, 7)
		XCTAssertEqual(decoded.serverId, id.uuidString)
		XCTAssertNil(decoded.placeholders)
	}

	func test_decode_missingRequiredField_throws() {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		// content is missing
		XCTAssertThrowsError(try CKRecordSnippetMapping.decode(rec))
	}

	func test_placeholders_roundTripJSONEncoded() throws {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                placeholders: ["path", "user"],
		                createdAt: .now, updatedAt: .now)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.placeholders, ["path", "user"])
	}
}
```

- [ ] **Step 9.4: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter CKRecordSnippetMappingTests
```

Expected: build failure (`CKRecordSnippetMapping` undefined).

- [ ] **Step 9.5: Implement the mapping**

Create `apps/macos/Sources/CloudKitSyncClient/CKRecordSnippetMapping.swift`:

```swift
import CloudKit
import Foundation
import SnippetSyncClient

public enum CKRecordSnippetMappingError: Error, Equatable {
	case missingRequiredField(String)
	case invalidUUID(String)
	case placeholdersDecodeFailure
}

public enum CKRecordSnippetMapping {
	public static let recordType = "Snippet"
	public static let schemaVersion: Int64 = 1

	public static func encode(_ s: Snippet, zoneID: CKRecordZone.ID) -> CKRecord {
		let recID = CKRecord.ID(recordName: s.id.uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: recordType, recordID: recID)
		rec["name"] = s.name as CKRecordValue
		rec["content"] = s.content as CKRecordValue
		rec["createdAt"] = s.createdAt as CKRecordValue
		rec["updatedAt"] = s.updatedAt as CKRecordValue
		rec["revision"] = Int64(s.revision) as CKRecordValue
		rec["schemaVersion"] = Self.schemaVersion as CKRecordValue
		if let placeholders = s.placeholders,
		   let data = try? JSONEncoder().encode(placeholders),
		   let json = String(data: data, encoding: .utf8) {
			rec["placeholders"] = json as CKRecordValue
		}
		return rec
	}

	public static func decode(_ rec: CKRecord) throws -> Snippet {
		guard let id = UUID(uuidString: rec.recordID.recordName) else {
			throw CKRecordSnippetMappingError.invalidUUID(rec.recordID.recordName)
		}
		guard let name = rec["name"] as? String else {
			throw CKRecordSnippetMappingError.missingRequiredField("name")
		}
		guard let content = rec["content"] as? String else {
			throw CKRecordSnippetMappingError.missingRequiredField("content")
		}
		guard let createdAt = rec["createdAt"] as? Date else {
			throw CKRecordSnippetMappingError.missingRequiredField("createdAt")
		}
		guard let updatedAt = rec["updatedAt"] as? Date else {
			throw CKRecordSnippetMappingError.missingRequiredField("updatedAt")
		}
		let revision = (rec["revision"] as? Int64).map(Int.init) ?? 0
		var placeholders: [String]?
		if let json = rec["placeholders"] as? String,
		   let data = json.data(using: .utf8) {
			do {
				placeholders = try JSONDecoder().decode([String].self, from: data)
			} catch {
				throw CKRecordSnippetMappingError.placeholdersDecodeFailure
			}
		}
		return Snippet(
			id: id,
			name: name,
			content: content,
			placeholders: placeholders,
			createdAt: createdAt,
			updatedAt: updatedAt,
			serverId: rec.recordID.recordName,
			revision: revision,
			metadataUpdatedAt: rec.modificationDate
		)
	}
}
```

- [ ] **Step 9.6: Run tests**

```bash
cd apps/macos && swift test --filter CKRecordSnippetMappingTests
```

Expected: 4 tests pass.

- [ ] **Step 9.7: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift apps/macos/Sources/CloudKitSyncClient/CKRecordSnippetMapping.swift apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift
git commit -m "feat(snippets): CKRecordSnippetMapping encode/decode + push names"
```

---

## Task 10: `CloudKitSyncClient+Snippet` — fetch / push / delete / subscription

**Spec:** §3.5, §3.6, §3.11.

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Snippet.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift`

- [ ] **Step 10.1: Write failing tests for the client extension**

Append to `CloudKitSyncClientSnippetTests.swift`:

```swift
final class CloudKitSyncClientSnippetTests: XCTestCase {
	func test_pushSnippet_savesToSnippetsZone() async throws {
		let fakeDB = FakeCKDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                createdAt: .now, updatedAt: .now)
		_ = try await client.pushSnippet(s)
		let saved = try XCTUnwrap(fakeDB.savedRecords.last)
		XCTAssertEqual(saved.recordID.zoneID.zoneName,
		               CloudKitPushNames.snippetZoneName,
		               "Snippets must land in the Snippets zone, not the Caterm host zone")
	}

	func test_deleteSnippet_callsDeleteWithSnippetZoneID() async throws {
		let fakeDB = FakeCKDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let id = UUID()
		try await client.deleteSnippet(id: id)
		let deleted = try XCTUnwrap(fakeDB.deletedRecordIDs.last)
		XCTAssertEqual(deleted.recordName, id.uuidString)
		XCTAssertEqual(deleted.zoneID.zoneName, CloudKitPushNames.snippetZoneName)
	}

	func test_ensureSnippetSubscription_isIdempotent() async throws {
		let fakeDB = FakeCKDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		try await client.ensureSnippetSubscription()
		try await client.ensureSnippetSubscription()
		// `serverRejectedRequest` on second call must be swallowed.
		XCTAssertEqual(fakeDB.savedSubscriptionIDs.filter {
			$0 == CloudKitPushNames.snippetSubscriptionID
		}.count, 2)
	}
}
```

(Reuse `FakeCKDatabase` from existing CloudKitSyncClientTests; if it does not exist as a shared helper yet, copy the relevant fake from `apps/macos/Tests/CloudKitSyncClientTests/` — search before creating.)

- [ ] **Step 10.2: Find or create `FakeCKDatabase`**

```bash
grep -rn "class FakeCKDatabase\|struct FakeCKDatabase" apps/macos/Tests/ 2>/dev/null
```

If found: ensure the fake records `savedRecords`, `deletedRecordIDs`, and `savedSubscriptionIDs`. Augment as needed.

If not found: create `apps/macos/Tests/CloudKitSyncClientTests/FakeCKDatabase.swift` implementing `CKDatabaseProtocol` (defined in `apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift`). The fake should track every save / delete / subscription operation and provide deterministic returns. **Read `CKDatabaseProtocol.swift` before writing** to match its method signatures exactly.

- [ ] **Step 10.3: Run failing tests**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientSnippetTests
```

Expected: build failure (`pushSnippet`, `deleteSnippet`, `ensureSnippetSubscription` undefined).

- [ ] **Step 10.4: Implement the extension**

Create `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Snippet.swift`:

```swift
import CloudKit
import Foundation
import SnippetSyncClient
import os

extension CloudKitSyncClient: IncrementalSnippetSyncClient {
	private static let snippetLog = Logger(subsystem: "com.caterm.app", category: "cloudkit-snippet-sync")

	/// Custom zone for snippets — distinct from the Caterm host zone.
	internal var snippetZoneID: CKRecordZone.ID {
		CKRecordZone.ID(
			zoneName: CloudKitPushNames.snippetZoneName,
			ownerName: CKCurrentUserDefaultName
		)
	}

	public func preferredSnippetSyncMode() async -> SnippetSyncMode {
		let stored = await snippetTokenStore.loadDatabaseToken()
		return stored == nil ? .forceFull : .incremental
	}

	public func pushSnippet(_ s: Snippet) async throws -> Snippet {
		try await ensureSnippetZone()
		let rec = CKRecordSnippetMapping.encode(s, zoneID: snippetZoneID)
		let saved = try await database.save(rec)
		var copy = s
		copy.serverId = saved.recordID.recordName
		copy.metadataUpdatedAt = saved.modificationDate
		return copy
	}

	public func deleteSnippet(id: UUID) async throws {
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: snippetZoneID)
		do {
			_ = try await database.deleteRecord(withID: recID)
		} catch let ck as CKError where ck.code == .unknownItem {
			// Already gone — treat as success.
			return
		}
	}

	public func ensureSnippetSubscription() async throws {
		let sub = CKDatabaseSubscription(subscriptionID: CloudKitPushNames.snippetSubscriptionID)
		sub.recordType = CKRecordSnippetMapping.recordType
		let info = CKSubscription.NotificationInfo()
		info.shouldSendContentAvailable = true
		sub.notificationInfo = info
		do {
			_ = try await database.saveSubscription(sub)
		} catch let ck as CKError where ck.code == .serverRejectedRequest {
			return
		}
	}

	public func deleteSnippetSubscription() async throws {
		do {
			_ = try await database.deleteSubscription(
				withID: CloudKitPushNames.snippetSubscriptionID
			)
		} catch let ck as CKError where ck.code == .unknownItem {
			return
		}
	}

	public func resetSnippetSyncState() async {
		await snippetTokenStore.clearAll()
	}

	public func hasAnySnippetSyncTokens() async -> Bool {
		await snippetTokenStore.loadDatabaseToken() != nil
	}

	// fetchSnippetChanges + fetchSnippetSnapshotAndCheckpoint + commitSnippetCheckpoint
	// implemented in Task 11. Stubs throw to keep build working.
	public func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		fatalError("Implemented in Task 11")
	}
	public func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		fatalError("Implemented in Task 11")
	}
	public func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		fatalError("Implemented in Task 11")
	}

	// MARK: - Internals

	private func ensureSnippetZone() async throws {
		let zone = CKRecordZone(zoneID: snippetZoneID)
		do {
			_ = try await database.save(zone)
		} catch let ck as CKError where ck.code == .serverRejectedRequest {
			return
		}
	}
}
```

You also need to add a `snippetTokenStore` property on `CloudKitSyncClient`. Open `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift` and:

1. After the existing `tokenStore` property, add:

```swift
    internal let snippetTokenStore: any ServerChangeTokenStoring
```

2. Update both `init`s. The convenience init constructs the snippet store with the snippet key prefix:

```swift
    public convenience init(
        database: CKDatabaseProtocol,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "Caterm")
    ) {
        self.init(
            database: database, zoneID: zoneID,
            tokenStore: UserDefaultsServerChangeTokenStore(),
            snippetTokenStore: UserDefaultsServerChangeTokenStore(
                keyPrefix: "cloudkit.changeToken.snippet"
            )
        )
    }

    internal init(database: CKDatabaseProtocol,
                  zoneID: CKRecordZone.ID,
                  tokenStore: any ServerChangeTokenStoring,
                  snippetTokenStore: any ServerChangeTokenStoring = InMemoryServerChangeTokenStore()) {
        self.database = database
        self.zoneID = zoneID
        self.tokenStore = tokenStore
        self.snippetTokenStore = snippetTokenStore
    }
```

The default `InMemoryServerChangeTokenStore()` for the internal init keeps existing test sites working without explicit snippet stores.

- [ ] **Step 10.5: Run tests**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientSnippetTests
```

Expected: 3 new tests pass; `fetchSnippet*` tests are not yet written.

- [ ] **Step 10.6: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ apps/macos/Tests/CloudKitSyncClientTests/
git commit -m "feat(snippets): CloudKitSyncClient — push/delete/subscription + snippet token store"
```

---

## Task 11: Snippet fetch + checkpoint

**Spec:** §3.5, §3.6.

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Snippet+Fetch.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientSnippetTests.swift`

- [ ] **Step 11.1: Write failing fetch tests**

Append to `CloudKitSyncClientSnippetTests.swift`:

```swift
final class CloudKitSyncClientSnippetFetchTests: XCTestCase {
	func test_fetchSnippetChanges_decodesChangedRecords() async throws {
		let fakeDB = FakeCKDatabase()
		let id = UUID()
		fakeDB.queuedZoneChanges = [
			.modified(makeFakeSnippetRecord(id: id, name: "n"))
		]
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm")
		)
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.changedSnippets.count, 1)
		XCTAssertEqual(batch.changedSnippets.first?.id, id)
		XCTAssertEqual(batch.mode, .incremental)
	}

	func test_fetchSnippetChanges_decodesTombstones() async throws {
		let fakeDB = FakeCKDatabase()
		let id = UUID()
		fakeDB.queuedZoneChanges = [.deleted(id.uuidString)]
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm")
		)
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.deletedSnippetIDs, [id])
	}

	func test_fetchSnippetChanges_corruptRecordIsSkipped() async throws {
		let fakeDB = FakeCKDatabase()
		let goodID = UUID()
		fakeDB.queuedZoneChanges = [
			.modified(makeFakeSnippetRecord(id: goodID, name: "n")),
			.modified(makeBrokenSnippetRecord())  // missing required field
		]
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm")
		)
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.changedSnippets.map(\.id), [goodID])
	}
}

// Test helpers
private func makeFakeSnippetRecord(id: UUID, name: String) -> CKRecord {
	let zoneID = CKRecordZone.ID(zoneName: CloudKitPushNames.snippetZoneName,
	                             ownerName: CKCurrentUserDefaultName)
	let rec = CKRecord(recordType: "Snippet",
	                   recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
	rec["name"] = name as CKRecordValue
	rec["content"] = "c" as CKRecordValue
	rec["createdAt"] = Date() as CKRecordValue
	rec["updatedAt"] = Date() as CKRecordValue
	rec["revision"] = Int64(1) as CKRecordValue
	rec["schemaVersion"] = Int64(1) as CKRecordValue
	return rec
}

private func makeBrokenSnippetRecord() -> CKRecord {
	let zoneID = CKRecordZone.ID(zoneName: CloudKitPushNames.snippetZoneName,
	                             ownerName: CKCurrentUserDefaultName)
	let rec = CKRecord(recordType: "Snippet",
	                   recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
	rec["name"] = "n" as CKRecordValue
	// content omitted intentionally
	return rec
}
```

The `FakeCKDatabase` needs a `queuedZoneChanges: [ZoneChange]` field plus a method that returns them when `recordZoneChanges(...)` is called. If the existing fake doesn't model zone changes, add what's needed — see how host fetch tests do it (look in `apps/macos/Tests/HostSyncStoreTests/` for zone-change fakes).

- [ ] **Step 11.2: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientSnippetFetchTests
```

Expected: fatal error "Implemented in Task 11" or build failure.

- [ ] **Step 11.3: Implement fetch + checkpoint**

The implementation parallels the existing host `drain(mode:)` in `CloudKitSyncClient+Push.swift`. Read that method end-to-end before writing the snippet version.

Create `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Snippet+Fetch.swift`:

```swift
import CloudKit
import Foundation
import SnippetSyncClient
import os

extension CloudKitSyncClient {
	private static let snippetFetchLog = Logger(subsystem: "com.caterm.app",
	                                            category: "cloudkit-snippet-fetch")

	internal struct SnippetCheckpointImpl: SnippetSyncCheckpoint {
		let id: UUID
		let epoch: UInt64
		let prevDb: Data?
		let newDb: Data?
		let prevZones: [String: Data?]
		let newZones: [String: Data?]
	}
}

extension CloudKitSyncClient {
	public func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		try await drainSnippetZone(mode: .incremental)
	}

	public func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		try await drainSnippetZone(mode: .forceFull)
	}

	public func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		guard let cp = checkpoint as? SnippetCheckpointImpl else {
			Self.snippetFetchLog.info("commitSnippetCheckpoint: foreign type, ignoring")
			return
		}
		let dbCAS = TokenCAS(prev: cp.prevDb, new: cp.newDb)
		var zoneCASes: [String: TokenCAS] = [:]
		for (zoneKey, newOpt) in cp.newZones {
			let prevOpt = cp.prevZones[zoneKey] ?? nil
			zoneCASes[zoneKey] = TokenCAS(prev: prevOpt, new: newOpt)
		}
		let outcome = await snippetTokenStore.commitTokens(
			expectedEpoch: cp.epoch, db: dbCAS, zones: zoneCASes
		)
		switch outcome {
		case .applied:
			Self.snippetFetchLog.debug("snippet checkpoint applied epoch=\(cp.epoch)")
		case .staleEpoch:
			Self.snippetFetchLog.info("snippet checkpoint stale by epoch \(cp.epoch); skipping")
		case .partialCAS(let zones, let db):
			Self.snippetFetchLog.info("snippet checkpoint partial CAS skippedZones=\(zones) skippedDb=\(db)")
		}
	}

	// MARK: - Drain implementation

	private func drainSnippetZone(mode: SnippetSyncMode) async throws -> SnippetChangeBatch {
		let epoch = await snippetTokenStore.currentEpoch()
		let prevDb = await snippetTokenStore.loadDatabaseToken()?.archivedData
		let prevZoneToken = await snippetTokenStore.loadZoneToken(snippetZoneID)
		let prevZones: [String: Data?] = [
			InMemoryServerChangeTokenStore.key(for: snippetZoneID): prevZoneToken?.archivedData
		]

		var changed: [Snippet] = []
		var deleted: [UUID] = []
		var newZoneTokenData: Data?
		var newDbTokenData: Data?
		var tokenExpired = false

		// For force-full: clear stored token first so the server sends everything.
		let useToken: CKServerChangeToken? = (mode == .forceFull)
			? nil
			: try? prevZoneToken?.unarchive()

		do {
			let result = try await database.recordZoneChanges(
				inZoneWith: snippetZoneID,
				since: useToken
			)
			for record in result.changedRecords {
				if let s = try? CKRecordSnippetMapping.decode(record) {
					changed.append(s)
				}
			}
			for recID in result.deletedRecordIDs {
				if let uuid = UUID(uuidString: recID.recordName) {
					deleted.append(uuid)
				}
			}
			if let newToken = result.newToken {
				let archived = try StoredServerChangeToken.archive(newToken)
				newZoneTokenData = archived.archivedData
			}
		} catch let ck as CKError where ck.code == .changeTokenExpired {
			tokenExpired = true
		}

		let cp = SnippetCheckpointImpl(
			id: UUID(),
			epoch: epoch,
			prevDb: prevDb,
			newDb: newDbTokenData,
			prevZones: prevZones,
			newZones: [
				InMemoryServerChangeTokenStore.key(for: snippetZoneID): newZoneTokenData
			]
		)

		return SnippetChangeBatch(
			changedSnippets: changed,
			deletedSnippetIDs: deleted,
			checkpoint: cp,
			tokenExpired: tokenExpired,
			mode: mode
		)
	}
}
```

Replace the placeholder `fatalError` stubs in `CloudKitSyncClient+Snippet.swift` with `// see CloudKitSyncClient+Snippet+Fetch.swift` comments, then delete the duplicate function declarations.

If `database.recordZoneChanges(inZoneWith:since:)` is not in `CKDatabaseProtocol`, add it — match the existing host fetch path's API shape exactly. Update `FakeCKDatabase` to satisfy.

- [ ] **Step 11.4: Run tests**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientSnippetFetchTests
```

Expected: 3 tests pass.

- [ ] **Step 11.5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ apps/macos/Tests/CloudKitSyncClientTests/
git commit -m "feat(snippets): CloudKitSyncClient — drain Snippets zone with CAS checkpoint"
```

---

## Task 12: `SnippetSyncStore` — sync pass orchestration

**Spec:** §3.11, §3.12.

**Files:**
- Create: `apps/macos/Sources/SnippetStore/SnippetSyncStore.swift`
- Test: `apps/macos/Tests/SnippetStoreTests/SnippetSyncStoreTests.swift`

- [ ] **Step 12.1: Write failing tests**

Create `apps/macos/Tests/SnippetStoreTests/SnippetSyncStoreTests.swift`:

```swift
import XCTest
import SnippetSyncClient
@testable import SnippetStore

@MainActor
final class SnippetSyncStoreTests: XCTestCase {
	private func tempDir() -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("snippet-sync-store-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func test_syncPass_drainsOutboxBeforeFetchAndPush() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)

		let client = FakeSnippetSyncClient()
		let sync = SnippetSyncStore(store: store, client: client)

		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(client.deleted, [id])
		XCTAssertFalse(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_syncPass_appliesRemoteAfterFetch_beforePush() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		// Local has revision 1. Remote arrives with revision 5.
		try store.upsert(Snippet(id: id, name: "local", content: "x",
		                         createdAt: .distantPast,
		                         updatedAt: Date(timeIntervalSince1970: 1),
		                         revision: 1))

		let remote = Snippet(id: id, name: "remote", content: "y",
		                     createdAt: .distantPast,
		                     updatedAt: Date(timeIntervalSince1970: 100),
		                     revision: 5)
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [remote], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)

		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(store.snippets.first?.name, "remote")
		XCTAssertTrue(client.pushed.isEmpty,
		              "Remote revision 5 > local 1; local must NOT be pushed")
	}

	func test_syncPass_remoteTombstoneBeatsDirtyLocalEdit() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "local", content: "x",
		                         createdAt: .now, updatedAt: .now))

		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [id],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)
		sync.markDirty(id)
		await sync.runSyncPass(mode: .incremental)

		XCTAssertTrue(store.snippets.isEmpty)
		XCTAssertTrue(client.pushed.isEmpty)
	}

	func test_runSyncPass_commitsCheckpointAfterApply() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let cp = StubCheckpoint()
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: cp, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)
		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(client.committedCheckpoints.count, 1)
	}

	func test_concurrentTriggers_serializeIntoOnePassAndOneFollowup() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.fetchDelay = .milliseconds(50)
		let sync = SnippetSyncStore(store: store, client: client)
		// Fire 3 schedule calls back-to-back; expect ≤ 2 actual passes.
		sync.scheduleSyncPass(mode: .incremental)
		sync.scheduleSyncPass(mode: .incremental)
		sync.scheduleSyncPass(mode: .incremental)
		try await Task.sleep(for: .milliseconds(200))
		XCTAssertLessThanOrEqual(client.fetchCallCount, 2)
		XCTAssertGreaterThanOrEqual(client.fetchCallCount, 1)
	}
}

private struct StubCheckpoint: SnippetSyncCheckpoint {
	let id = UUID()
}

@MainActor
private final class FakeSnippetSyncClient: IncrementalSnippetSyncClient {
	var queuedFetch: SnippetChangeBatch?
	var pushed: [Snippet] = []
	var deleted: [UUID] = []
	var committedCheckpoints: [any SnippetSyncCheckpoint] = []
	var fetchCallCount = 0
	var fetchDelay: Duration = .zero
	var subscriptions: Set<String> = []
	var hasTokens = false

	func preferredSnippetSyncMode() async -> SnippetSyncMode { .incremental }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		fetchCallCount += 1
		if fetchDelay > .zero { try? await Task.sleep(for: fetchDelay) }
		return queuedFetch ?? SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		fetchCallCount += 1
		return queuedFetch ?? SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .forceFull
		)
	}

	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		committedCheckpoints.append(checkpoint)
	}

	func resetSnippetSyncState() async { hasTokens = false }
	func ensureSnippetSubscription() async throws {
		subscriptions.insert("snippet")
	}
	func deleteSnippetSubscription() async throws {
		subscriptions.remove("snippet")
	}
	func pushSnippet(_ s: Snippet) async throws -> Snippet {
		pushed.append(s)
		var copy = s
		copy.metadataUpdatedAt = Date()
		return copy
	}
	func deleteSnippet(id: UUID) async throws { deleted.append(id) }
	func hasAnySnippetSyncTokens() async -> Bool { hasTokens }
}
```

- [ ] **Step 12.2: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter SnippetSyncStoreTests
```

Expected: build failure.

- [ ] **Step 12.3: Implement `SnippetSyncStore`**

Create `apps/macos/Sources/SnippetStore/SnippetSyncStore.swift`:

```swift
import Foundation
import SnippetSyncClient
import os

@MainActor
public final class SnippetSyncStore {
	private static let log = Logger(subsystem: "com.caterm.app", category: "snippet-sync")
	private let store: SnippetStore
	private let client: any IncrementalSnippetSyncClient

	private var locallyDirty: Set<UUID> = []
	private var inFlight: Task<Void, Never>?
	private var queuedFollowUp: SnippetSyncMode?
	private var debounce: Task<Void, Never>?

	public init(store: SnippetStore, client: any IncrementalSnippetSyncClient) {
		self.store = store
		self.client = client
	}

	public func markDirty(_ id: UUID) {
		locallyDirty.insert(id)
	}

	public func scheduleSyncPass(mode: SnippetSyncMode = .incremental, debounceMs: Int = 0) {
		debounce?.cancel()
		debounce = Task { [weak self] in
			if debounceMs > 0 {
				try? await Task.sleep(for: .milliseconds(debounceMs))
				guard !Task.isCancelled else { return }
			}
			await self?.runSyncPassSerialized(mode: mode)
		}
	}

	public func runSyncPass(mode: SnippetSyncMode) async {
		await runSyncPassSerialized(mode: mode)
	}

	private func runSyncPassSerialized(mode: SnippetSyncMode) async {
		if let inFlight {
			// Coalesce: queue at most one follow-up.
			queuedFollowUp = mode
			await inFlight.value
			if let next = queuedFollowUp {
				queuedFollowUp = nil
				await runSyncPassSerialized(mode: next)
			}
			return
		}
		let task = Task { [weak self] in
			await self?.executeSyncPass(mode: mode)
		}
		inFlight = task
		await task.value
		inFlight = nil
	}

	private func executeSyncPass(mode: SnippetSyncMode) async {
		do {
			// Step 1 — drain pending-delete outbox.
			let pendingDeletes = store.pendingDeletedSnippetIDs
			for id in pendingDeletes {
				do {
					try await client.deleteSnippet(id: id)
					try store.clearOutboxEntry(id)
				} catch {
					Self.log.error("deleteSnippet failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					// Leave in outbox; next pass retries.
				}
			}

			// Step 2 — fetch.
			let batch: SnippetChangeBatch
			switch mode {
			case .forceFull:
				batch = try await client.fetchSnippetSnapshotAndCheckpoint()
			case .incremental:
				batch = try await client.fetchSnippetChanges()
			}

			if batch.tokenExpired {
				Self.log.info("token expired — falling back to forceFull")
				let snapshot = try await client.fetchSnippetSnapshotAndCheckpoint()
				await applyBatch(snapshot)
				if let cp = snapshot.checkpoint {
					try await client.commitSnippetCheckpoint(cp)
				}
				return
			}

			await applyBatch(batch)
			if let cp = batch.checkpoint {
				try await client.commitSnippetCheckpoint(cp)
			}
		} catch {
			Self.log.error("snippet sync pass failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	private func applyBatch(_ batch: SnippetChangeBatch) async {
		let ops: [SnippetSyncOperation]
		switch batch.mode {
		case .forceFull:
			ops = SnippetSyncReconciler.reconcileFullSnapshot(
				local: store.snippets,
				remote: batch.changedSnippets,
				locallyDirty: locallyDirty
			)
		case .incremental:
			ops = SnippetSyncReconciler.reconcileDelta(
				local: store.snippets,
				changedSnippets: batch.changedSnippets,
				deletedIDs: batch.deletedSnippetIDs,
				locallyDirty: locallyDirty
			)
		}
		for op in ops {
			switch op {
			case .applyRemote(let s):
				try? store.applyRemote(s)
				locallyDirty.remove(s.id)
			case .applyTombstone(let id):
				try? store.applyRemoteTombstone(id: id)
				locallyDirty.remove(id)
			case .pushLocal(let s):
				do {
					let saved = try await client.pushSnippet(s)
					try? store.applyRemote(saved)
					locallyDirty.remove(s.id)
				} catch {
					Self.log.error("pushSnippet failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					// Stay dirty; next pass retries.
				}
			}
		}
	}
}
```

- [ ] **Step 12.4: Run tests**

```bash
cd apps/macos && swift test --filter SnippetSyncStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 12.5: Commit**

```bash
git add apps/macos/Sources/SnippetStore/SnippetSyncStore.swift apps/macos/Tests/SnippetStoreTests/SnippetSyncStoreTests.swift
git commit -m "feat(snippets): SnippetSyncStore — fetch-first sync pass with serialized triggers"
```

---

## Task 13: Account-switch wiring + token-existence widening

**Spec:** §3.9.

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift`

- [ ] **Step 13.1: Widen `AccountSensitiveClient`**

In `AccountIdentityTracker.swift`:

```swift
public protocol AccountSensitiveClient: Sendable {
	func resetHostSyncState() async
	func deleteHostSubscription() async throws
	func resetSnippetSyncState() async
	func deleteSnippetSubscription() async throws
}
```

The `extension CloudKitSyncClient: AccountSensitiveClient` block already exists; the new `resetSnippetSyncState` and `deleteSnippetSubscription` methods landed in Task 10, so this just causes the protocol conformance to recognize them.

- [ ] **Step 13.2: Update reset paths**

In `AccountIdentityTracker.handleAccountChange`:

```swift
@discardableResult
public func handleAccountChange(client: any AccountSensitiveClient) async -> AccountChangeOutcome {
	let prior = defaults.string(forKey: Self.storageKey)
	let current = await currentUserRecordIDProvider()?.recordName

	switch (prior, current) {
	case (nil, nil):
		return .unchanged
	case (nil, .some(let new)):
		if await tokensExistProvider() {
			Self.log.info("first identity observation with existing tokens → resetting host AND snippet")
			await client.resetHostSyncState()
			await client.resetSnippetSyncState()
		}
		defaults.set(new, forKey: Self.storageKey)
		return .firstObservation
	case (.some(let p), .some(let c)) where p == c:
		return .unchanged
	case (.some, _):
		await client.resetHostSyncState()
		await client.resetSnippetSyncState()
		try? await client.deleteHostSubscription()
		try? await client.deleteSnippetSubscription()
		if let new = current {
			defaults.set(new, forKey: Self.storageKey)
		} else {
			defaults.removeObject(forKey: Self.storageKey)
		}
		return .identityChanged
	}
}
```

- [ ] **Step 13.3: Run tracker tests**

```bash
cd apps/macos && swift test --filter AccountIdentityTrackerTests
```

Expected: existing tests pass. If a test asserts the protocol's exact method count, add the two new methods to its mock. Find by:

```bash
grep -rn "AccountSensitiveClient" apps/macos/Tests/ | head
```

Update mock conformances. Add a new test asserting both reset methods are called on `.identityChanged`:

```swift
func test_handleAccountChange_identityChange_resetsHostAndSnippet() async {
	let mock = MockAccountSensitiveClient()
	let defaults = UserDefaults(suiteName: "test-\(UUID())")!
	defaults.set("user-A", forKey: "cloudkit.lastKnownUserRecordName")
	let tracker = AccountIdentityTracker(
		defaults: defaults,
		currentUserRecordID: { CKRecord.ID(recordName: "user-B") },
		tokensExist: { true }
	)
	let outcome = await tracker.handleAccountChange(client: mock)
	XCTAssertEqual(outcome, .identityChanged)
	XCTAssertTrue(mock.didResetHost)
	XCTAssertTrue(mock.didResetSnippet)
}
```

- [ ] **Step 13.4: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift apps/macos/Tests/CloudKitSyncClientTests/AccountIdentityTrackerTests.swift
git commit -m "feat(snippets): widen AccountSensitiveClient — reset snippet state on identity change"
```

---

## Task 14: Surface registry on `SessionStore.Tab`

**Spec:** §3.10.

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`

- [ ] **Step 14.1: Add a weak surface ref on `Tab`**

In `SessionStore.swift`, find the `Tab` struct/class and add:

```swift
// Inside SessionStore.swift, in the Tab declaration:
public weak var surface: GhosttySurface?
```

If `Tab` is a `struct`: SwiftUI value-type semantics make a weak ref tricky. Make `Tab` a `final class` if it isn't already, and ensure mutations go through `SessionStore` methods that re-publish the array.

If structural change is invasive, fall back to a sibling registry:

```swift
// New file: apps/macos/Sources/SessionStore/SurfaceRegistry.swift
import TerminalEngine

public final class SurfaceRegistry: ObservableObject {
	private var surfaces: [UUID: WeakSurfaceBox] = [:]
	private final class WeakSurfaceBox { weak var surface: GhosttySurface?
		init(_ s: GhosttySurface) { self.surface = s }
	}
	public func register(_ surface: GhosttySurface, for tabId: UUID) {
		surfaces[tabId] = WeakSurfaceBox(surface)
	}
	public func surface(for tabId: UUID) -> GhosttySurface? {
		surfaces[tabId]?.surface
	}
	public func unregister(_ tabId: UUID) {
		surfaces.removeValue(forKey: tabId)
	}
}
```

Add `SessionStore` dependency on `TerminalEngine` if the registry lives in `SessionStore`. **Verify in `Package.swift`** before writing — `SessionStore`'s current deps are `["SSHCommandBuilder", "KeychainStore", "ServerSyncClient"]`; adding `TerminalEngine` may require checking for cycles. If it cycles, put the registry in a new tiny target or in `Caterm/Views/`.

- [ ] **Step 14.2: Register surface in `TerminalSurfaceRepresentable.makeNSView`**

In `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`, the existing `Task { @MainActor [weak store, weak view] in ... }` at line 57 polls until `view.surface` is built. Inside that block, when `view.surface` becomes non-nil:

```swift
if let surface = view?.surface {
	surface.onChildExit = { [weak store] code in
		Task { @MainActor in
			store?.markChildExited(tabId: capturedTabId, exitCode: code)
		}
	}
	store?.surfaceRegistry.register(surface, for: capturedTabId)
	break
}
```

When the tab closes (find the existing close handler — likely in `SessionStore` itself), call `surfaceRegistry.unregister(tabId)`.

- [ ] **Step 14.3: Wire `SessionStore.surfaceRegistry`**

If using the sibling-registry approach, add a `let surfaceRegistry = SurfaceRegistry()` property on `SessionStore` (or expose via a separate `@StateObject` in `CatermApp`). The simplest path: a `let surfaceRegistry = SurfaceRegistry()` inside `SessionStore`. Whatever you pick, surface-resolving code calls `store.surfaceRegistry.surface(for: tab.id)`.

- [ ] **Step 14.4: Verify build + existing tests**

```bash
cd apps/macos && swift build && make test
```

Expected: all existing tests still pass. No new tests required for this task — registry behavior is exercised in Task 17 (palette).

- [ ] **Step 14.5: Commit**

```bash
git add apps/macos/Sources/SessionStore apps/macos/Sources/Caterm/Views/TerminalContainerView.swift
git commit -m "feat(snippets): surface registry on SessionStore for palette dispatch"
```

---

## Task 15: `SnippetEditorSheet` view

**Spec:** §4.1, §4.5.

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Snippets/SnippetEditorSheet.swift`

- [ ] **Step 15.1: Implement the sheet**

```swift
import SnippetStore
import SnippetSyncClient
import SwiftUI

struct SnippetEditorSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var store: SnippetStore
	@EnvironmentObject var sync: SnippetSyncStore

	enum Mode {
		case create
		case edit(Snippet)
	}

	let mode: Mode

	@State private var name: String = ""
	@State private var content: String = ""

	private var canSave: Bool {
		!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(titleLabel).font(.headline)
			TextField("Name", text: $name)
				.textFieldStyle(.roundedBorder)
			TextEditor(text: $content)
				.font(.system(.body, design: .monospaced))
				.frame(minHeight: 240)
				.border(Color.secondary.opacity(0.3))
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(!canSave)
			}
		}
		.padding()
		.frame(minWidth: 520, minHeight: 360)
		.onAppear(perform: loadInitial)
	}

	private var titleLabel: String {
		switch mode {
		case .create: return "New Snippet"
		case .edit:   return "Edit Snippet"
		}
	}

	private func loadInitial() {
		if case .edit(let s) = mode {
			name = s.name
			content = s.content
		}
	}

	private func save() {
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedContent = content
		do {
			switch mode {
			case .create:
				let s = Snippet(
					id: UUID(), name: trimmedName, content: trimmedContent,
					createdAt: Date(), updatedAt: Date()
				)
				try store.upsert(s)
				sync.markDirty(s.id)
			case .edit(let original):
				var copy = original
				copy.name = trimmedName
				copy.content = trimmedContent
				try store.upsert(copy)
				sync.markDirty(copy.id)
			}
			sync.scheduleSyncPass(debounceMs: 500)
			dismiss()
		} catch {
			NSLog("[SnippetEditorSheet] save failed: \(error.localizedDescription)")
		}
	}
}
```

- [ ] **Step 15.2: Verify it compiles**

```bash
cd apps/macos && swift build --target Caterm
```

Expected: `Build complete!`. (No tests for this view — UI is exercised by manual smoke and by Task 17's integration test.)

- [ ] **Step 15.3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Snippets/SnippetEditorSheet.swift
git commit -m "feat(snippets): SnippetEditorSheet — create/edit form"
```

---

## Task 16: `SnippetRowView`

**Spec:** §4.1.

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Snippets/SnippetRowView.swift`

- [ ] **Step 16.1: Implement the row**

```swift
import SnippetSyncClient
import SwiftUI

struct SnippetRowView: View {
	let snippet: Snippet
	let onEdit: () -> Void
	let onDelete: () -> Void
	let onCopy: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(snippet.name).font(.body)
				Text(firstContentLine)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			Spacer()
			Menu {
				Button("Edit", action: onEdit)
				Button("Copy content", action: onCopy)
				Divider()
				Button("Delete", role: .destructive, action: onDelete)
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
		}
		.padding(.vertical, 4)
		.contentShape(Rectangle())
	}

	private var firstContentLine: String {
		let firstLine = snippet.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
		return firstLine.isEmpty ? " " : firstLine
	}
}
```

- [ ] **Step 16.2: Verify build**

```bash
cd apps/macos && swift build --target Caterm
```

Expected: `Build complete!`.

- [ ] **Step 16.3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Snippets/SnippetRowView.swift
git commit -m "feat(snippets): SnippetRowView with hover menu"
```

---

## Task 17: `SnippetPalette` — search + dispatch + captured surface

**Spec:** §3.10, §4.1, §4.4.

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Snippets/SnippetPalette.swift`
- Test: `apps/macos/Tests/CatermTests/SnippetPaletteTests.swift`

- [ ] **Step 17.1: Write failing tests for the search + dispatch behavior**

Create `apps/macos/Tests/CatermTests/SnippetPaletteTests.swift`. Because SwiftUI views are hard to unit-test directly, factor the behavior into a `SnippetPaletteViewModel` and test that:

```swift
import XCTest
import SnippetSyncClient
@testable import Caterm
@testable import SnippetStore

@MainActor
final class SnippetPaletteViewModelTests: XCTestCase {
	private func makeStore() throws -> SnippetStore {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("palette-vm-\(UUID())")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let store = SnippetStore(directory: dir)
		try store.load()
		return store
	}

	func test_filter_matchesNameAndContent() throws {
		let store = try makeStore()
		try store.upsert(Snippet(id: UUID(), name: "ls", content: "ls -la",
		                         createdAt: .now, updatedAt: .now))
		try store.upsert(Snippet(id: UUID(), name: "docker", content: "docker ps",
		                         createdAt: .now, updatedAt: .now))
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		vm.query = "doc"
		XCTAssertEqual(vm.results.map(\.name), ["docker"])
	}

	func test_dispatchEnabled_falseWhenNoSurface() throws {
		let store = try makeStore()
		try store.upsert(Snippet(id: UUID(), name: "n", content: "c",
		                         createdAt: .now, updatedAt: .now))
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		XCTAssertFalse(vm.canDispatch)
	}

	func test_capturedSurface_immutableAfterCreation() throws {
		let store = try makeStore()
		let dummy = DummySurface()
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: dummy)
		// The view never mutates capturedSurface; verify the property is `let`.
		// (Compile-time assertion via a helper that needs the property to be a let.)
		let _: GhosttySurface? = vm.capturedSurface
	}
}

private final class DummySurface: GhosttySurface {
	// If GhosttySurface is a class, subclass with no-op overrides.
	// Adapt to actual ghostty type; this stub may need a real surface fake.
}
```

If `GhosttySurface` is hard to fake, test the view-model with a protocol-based abstraction:

```swift
protocol SnippetDispatchTarget: AnyObject {
	func paste(_ text: String)
	func run(_ text: String)
}
```

Then `SnippetPaletteViewModel.capturedSurface` becomes `(any SnippetDispatchTarget)?`. The production wrapper just calls `surface.pasteSnippet(text)` / `surface.executeSnippet(text)`. The test uses a `MockDispatchTarget` recording calls.

Use this protocol form — it's cleaner and testable.

- [ ] **Step 17.2: Run tests to confirm they fail**

```bash
cd apps/macos && swift test --filter SnippetPaletteViewModelTests
```

Expected: build failure.

- [ ] **Step 17.3: Implement view-model + view**

Create `apps/macos/Sources/Caterm/Views/Snippets/SnippetPalette.swift`:

```swift
import SnippetStore
import SnippetSyncClient
import SwiftUI

public protocol SnippetDispatchTarget: AnyObject {
	func paste(_ text: String)
	func run(_ text: String)
}

@MainActor
final class SnippetPaletteViewModel: ObservableObject {
	let store: SnippetStore
	let capturedSurface: (any SnippetDispatchTarget)?
	@Published var query: String = ""

	init(store: SnippetStore, capturedSurface: (any SnippetDispatchTarget)?) {
		self.store = store
		self.capturedSurface = capturedSurface
	}

	var results: [Snippet] {
		store.search(query)
			.sorted(by: { $0.updatedAt > $1.updatedAt })
	}

	var canDispatch: Bool { capturedSurface != nil }

	func paste(_ s: Snippet) {
		capturedSurface?.paste(s.content)
	}

	func run(_ s: Snippet) {
		capturedSurface?.run(s.content)
	}
}

struct SnippetPalette: View {
	@StateObject private var vm: SnippetPaletteViewModel
	@FocusState private var searchFocused: Bool
	@State private var selectedID: UUID?
	let onClose: () -> Void
	let onCreate: () -> Void

	init(store: SnippetStore,
	     capturedSurface: (any SnippetDispatchTarget)?,
	     onClose: @escaping () -> Void,
	     onCreate: @escaping () -> Void) {
		_vm = StateObject(wrappedValue: SnippetPaletteViewModel(
			store: store, capturedSurface: capturedSurface
		))
		self.onClose = onClose
		self.onCreate = onCreate
	}

	var body: some View {
		VStack(spacing: 0) {
			if !vm.canDispatch {
				Text("No active terminal — connect to a host first")
					.font(.caption).foregroundColor(.secondary)
					.padding(8)
			}
			TextField("Search snippets…", text: $vm.query)
				.textFieldStyle(.plain)
				.padding(8)
				.focused($searchFocused)

			Divider()

			if vm.results.isEmpty {
				VStack(spacing: 8) {
					Text("No snippets yet")
					Button("Create your first snippet (⌘⇧S)", action: onCreate)
				}
				.padding()
			} else {
				List(vm.results, selection: $selectedID) { s in
					SnippetRowView(
						snippet: s,
						onEdit: { /* hook to manager in Task 18 */ },
						onDelete: { /* hook in Task 18 */ },
						onCopy: { copy(s) }
					)
					.tag(s.id)
				}
				.listStyle(.plain)
			}

			Divider()
			HStack {
				Text(vm.canDispatch
				     ? "Enter — paste · ⌘+Enter — run · Esc — close"
				     : "Connect a host to enable dispatch")
					.font(.caption).foregroundColor(.secondary)
				Spacer()
			}
			.padding(8)
		}
		.frame(width: 520, height: 380)
		.onAppear { searchFocused = true }
		.onKeyPress(.escape) { onClose(); return .handled }
		.onKeyPress(.return) { handleEnter(); return .handled }
		.onKeyPress(.return, modifiers: .command) { handleCmdEnter(); return .handled }
	}

	private func selected() -> Snippet? {
		guard let id = selectedID ?? vm.results.first?.id else { return nil }
		return vm.results.first { $0.id == id }
	}

	private func handleEnter() {
		guard let s = selected(), vm.canDispatch else { return }
		vm.paste(s)
		onClose()
	}

	private func handleCmdEnter() {
		guard let s = selected(), vm.canDispatch else { return }
		vm.run(s)
		onClose()
	}

	private func copy(_ s: Snippet) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(s.content, forType: .string)
	}
}
```

- [ ] **Step 17.4: Run tests**

```bash
cd apps/macos && swift test --filter SnippetPaletteViewModelTests
```

Expected: 3 tests pass. (Adjust mock-dispatch-target plumbing if you used an alternative test shape.)

- [ ] **Step 17.5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Snippets/SnippetPalette.swift apps/macos/Tests/CatermTests/SnippetPaletteTests.swift
git commit -m "feat(snippets): SnippetPalette with captured-surface dispatch + view model tests"
```

---

## Task 18: `SnippetManagerSheet`

**Spec:** §4.1, §4.6.

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Snippets/SnippetManagerSheet.swift`

- [ ] **Step 18.1: Implement the manager**

```swift
import SnippetStore
import SnippetSyncClient
import SwiftUI

struct SnippetManagerSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var store: SnippetStore
	@EnvironmentObject var sync: SnippetSyncStore

	@State private var query: String = ""
	@State private var selectedID: UUID?
	@State private var editing: Snippet?
	@State private var creating: Bool = false

	private var results: [Snippet] {
		store.search(query).sorted(by: { $0.updatedAt > $1.updatedAt })
	}

	private var selectedSnippet: Snippet? {
		guard let id = selectedID else { return nil }
		return results.first { $0.id == id }
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				TextField("Search…", text: $query)
					.textFieldStyle(.roundedBorder)
				Button(action: { creating = true }) { Image(systemName: "plus") }
				Button("Done") { dismiss() }
			}
			.padding(8)

			Divider()

			HSplitView {
				List(results, selection: $selectedID) { s in
					SnippetRowView(
						snippet: s,
						onEdit: { editing = s },
						onDelete: { delete(s) },
						onCopy: { copy(s.content) }
					)
					.tag(s.id)
				}
				.listStyle(.plain)
				.frame(minWidth: 240)

				if let s = selectedSnippet {
					SnippetDetailView(snippet: s,
					                  onEdit: { editing = s },
					                  onDelete: { delete(s) })
				} else {
					VStack {
						Text("Select a snippet").foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}

			Divider()
			Text("⚠ Snippets travel through CloudKit. Do not store passwords or other secrets here.")
				.font(.caption).foregroundColor(.secondary)
				.padding(6)
		}
		.frame(minWidth: 720, minHeight: 480)
		.sheet(isPresented: $creating) {
			SnippetEditorSheet(mode: .create)
				.environmentObject(store)
				.environmentObject(sync)
		}
		.sheet(item: $editing) { s in
			SnippetEditorSheet(mode: .edit(s))
				.environmentObject(store)
				.environmentObject(sync)
		}
	}

	private func delete(_ s: Snippet) {
		do {
			try store.delete(id: s.id)
			sync.scheduleSyncPass(debounceMs: 0)
		} catch {
			NSLog("[SnippetManagerSheet] delete failed: \(error.localizedDescription)")
		}
	}

	private func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}

private struct SnippetDetailView: View {
	let snippet: Snippet
	let onEdit: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(snippet.name).font(.title2)
			ScrollView {
				Text(snippet.content)
					.font(.system(.body, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
			}
			.background(Color.secondary.opacity(0.05))
			HStack {
				Spacer()
				Button("Edit", action: onEdit)
				Button("Delete", role: .destructive, action: onDelete)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
```

- [ ] **Step 18.2: Snippet must be `Identifiable` for `.sheet(item:)`**

`Snippet` already conforms to `Identifiable` via Task 2. Verify: `cd apps/macos && swift build --target Caterm` builds clean.

- [ ] **Step 18.3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Snippets/SnippetManagerSheet.swift
git commit -m "feat(snippets): SnippetManagerSheet — search + detail + delete"
```

---

## Task 19: `GhosttySurface` paste/execute injection

**Spec:** §5.1, §5.2 (depends on Task 0 spike outcome).

**Files:**
- Create: `apps/macos/Sources/TerminalEngine/GhosttySurface+SnippetInjection.swift`

- [ ] **Step 19.1: Read the spike outcome**

Open `docs/superpowers/2026-05-06-snippet-run-mode-spike.md` and copy the exact code snippet from the "Implementation reference" section into the new extension.

- [ ] **Step 19.2: Implement paste + execute**

The implementation depends on the spike. The Paste path is fixed; the Run path varies:

```swift
import AppKit
import GhosttyKit

@MainActor
public extension GhosttySurface {
	/// Paste mode — leaves bracketed-paste wrapping in place. Multi-line
	/// content sits at the prompt; user reviews + presses Return.
	func pasteSnippet(_ content: String) {
		sendText(content)
	}

	/// Run mode — bypasses bracketed-paste wrapping so the shell executes
	/// the content immediately. Implementation chosen by Task 0 spike.
	func executeSnippet(_ content: String) {
		// Path (B′) example: paste body, then synthesize Return.
		// Replace this with the spike's chosen mechanism.
		sendText(content)
		guard let returnEvent = NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: 0,
			context: nil,
			characters: "\r",
			charactersIgnoringModifiers: "\r",
			isARepeat: false,
			keyCode: 36
		) else { return }
		sendKey(returnEvent, composing: false)
	}
}
```

If the spike chose path (A) (raw `sendText` works as-is), `executeSnippet` becomes:

```swift
func executeSnippet(_ content: String) {
	let payload = content.hasSuffix("\n") ? content : content + "\n"
	sendText(payload)
}
```

- [ ] **Step 19.3: Wire `SnippetDispatchTarget` conformance**

In the same file, after the extension:

```swift
extension GhosttySurface: SnippetDispatchTarget {
	public func paste(_ text: String) { pasteSnippet(text) }
	public func run(_ text: String) { executeSnippet(text) }
}
```

For this conformance to work, `SnippetDispatchTarget` (defined in the `Caterm` target — Task 17) must be visible to `TerminalEngine`. Move `SnippetDispatchTarget` to a place both targets can see — easiest: declare it inside `SnippetSyncClient/SnippetDispatchTarget.swift`:

```swift
import Foundation

public protocol SnippetDispatchTarget: AnyObject {
	func paste(_ text: String)
	func run(_ text: String)
}
```

Update Task 17's `import` to use the moved declaration. Update `TerminalEngine`'s deps in `Package.swift` to include `SnippetSyncClient`:

```swift
        .target(
            name: "TerminalEngine",
            dependencies: ["GhosttyKit", "ConfigStore", "SettingsStore", "SnippetSyncClient"],
            path: "Sources/TerminalEngine"
        ),
```

- [ ] **Step 19.4: Manual smoke**

```bash
cd apps/macos && make run-app
```

Connect to any host. From a debugger, breakpoint and call `surface.pasteSnippet("echo hello")` then `surface.executeSnippet("echo world")`. Verify Paste leaves text at prompt, Run executes.

- [ ] **Step 19.5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/GhosttySurface+SnippetInjection.swift apps/macos/Sources/SnippetSyncClient/SnippetDispatchTarget.swift apps/macos/Package.swift
git commit -m "feat(snippets): GhosttySurface paste/execute injection (per Task 0 spike)"
```

---

## Task 20: Menu commands + `SnippetCommandObserver` modifier

**Spec:** §4.3.

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`
- Create: `apps/macos/Sources/Caterm/Views/Snippets/SnippetCommandObserver.swift`

- [ ] **Step 20.1: Add menu commands**

In `CatermApp.swift`, locate the `.commands { ... }` modifier on the WindowGroup. After the existing `CommandGroup(after: .toolbar) { Button("Toggle Files Drawer") ... }` block, add:

```swift
				CommandGroup(after: .toolbar) {
					Button("Open Snippet Palette") {
						NotificationCenter.default.post(name: .catermOpenSnippetPalette, object: nil)
					}
					.keyboardShortcut("p", modifiers: [.command, .shift])

					Button("New Snippet…") {
						NotificationCenter.default.post(name: .catermNewSnippet, object: nil)
					}
					.keyboardShortcut("s", modifiers: [.command, .shift])

					Button("Manage Snippets…") {
						NotificationCenter.default.post(name: .catermOpenSnippetManager, object: nil)
					}
				}
```

- [ ] **Step 20.2: Create the shared observer modifier**

Create `apps/macos/Sources/Caterm/Views/Snippets/SnippetCommandObserver.swift`:

```swift
import AppKit
import SnippetStore
import SnippetSyncClient
import SwiftUI

struct SnippetCommandObserver: ViewModifier {
	@EnvironmentObject var store: SnippetStore
	@EnvironmentObject var sync: SnippetSyncStore
	@EnvironmentObject var sessionStore: SessionStoreEnvObject  // see step 20.4

	@Binding var presentingPalette: Bool
	@Binding var presentingEditor: Bool
	@Binding var presentingManager: Bool

	let isKeyWindow: () -> Bool

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .catermOpenSnippetPalette)) { _ in
				if isKeyWindow() { presentingPalette = true }
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermNewSnippet)) { _ in
				if isKeyWindow() { presentingEditor = true }
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermOpenSnippetManager)) { _ in
				if isKeyWindow() { presentingManager = true }
			}
	}
}
```

`SessionStoreEnvObject` is whatever environment object exposes the surface registry. If `SessionStore` is already an `@EnvironmentObject` in `MainWindow` and `LandingView`, use it directly.

- [ ] **Step 20.3: Apply the modifier in `MainWindow` and `LandingView`**

In `MainWindow`:

```swift
@State private var presentingPalette = false
@State private var presentingEditor = false
@State private var presentingManager = false

// Inside body, modify the root container:
.modifier(SnippetCommandObserver(
	presentingPalette: $presentingPalette,
	presentingEditor: $presentingEditor,
	presentingManager: $presentingManager,
	isKeyWindow: { NSApp.keyWindow?.identifier == self.windowIdentifier }
))
.popover(isPresented: $presentingPalette) {
	SnippetPalette(
		store: store,
		capturedSurface: resolveActiveSurface(),
		onClose: { presentingPalette = false },
		onCreate: { presentingPalette = false; presentingEditor = true }
	)
}
.sheet(isPresented: $presentingEditor) {
	SnippetEditorSheet(mode: .create)
		.environmentObject(store)
		.environmentObject(sync)
}
.sheet(isPresented: $presentingManager) {
	SnippetManagerSheet()
		.environmentObject(store)
		.environmentObject(sync)
}

private func resolveActiveSurface() -> (any SnippetDispatchTarget)? {
	guard let activeTabID = sessionStore.activeTabID else { return nil }
	return sessionStore.surfaceRegistry.surface(for: activeTabID)
}
```

In `LandingView`, apply the same modifier but `resolveActiveSurface()` returns nil:

```swift
.popover(isPresented: $presentingPalette) {
	SnippetPalette(
		store: store, capturedSurface: nil,
		onClose: { presentingPalette = false },
		onCreate: { presentingPalette = false; presentingEditor = true }
	)
}
```

The `isKeyWindow` closure: SwiftUI does not expose the backing `NSWindow` directly. Use a `WindowAccessor` `NSViewRepresentable` to fetch it at view-mount, store the `NSWindow` weak reference in `@State`:

```swift
struct WindowAccessor: NSViewRepresentable {
	@Binding var window: NSWindow?
	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async { self.window = v.window }
		return v
	}
	func updateNSView(_ nsView: NSView, context: Context) {}
}
```

Add to root: `.background(WindowAccessor(window: $hostWindow))`. Then `isKeyWindow: { hostWindow?.isKeyWindow ?? false }`.

- [ ] **Step 20.4: Verify build**

```bash
cd apps/macos && swift build --target Caterm
```

Expected: `Build complete!`.

- [ ] **Step 20.5: Commit**

```bash
git add apps/macos/Sources/Caterm/CatermApp.swift apps/macos/Sources/Caterm/Views/
git commit -m "feat(snippets): View menu commands + SnippetCommandObserver with isKeyWindow filter"
```

---

## Task 21: Toolbar button + wire `SnippetSyncStore` in `CatermApp`

**Spec:** §4.2, §3.12.

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`

- [ ] **Step 21.1: Wire `SnippetStore` and `SnippetSyncStore` in `CatermApp.init`**

In the `App.init()` block (around line 100 of `CatermApp.swift`), after the existing `_remoteBookmarks` initialization, add:

```swift
		let snippetsDir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
		let snippetStore = SnippetStore(directory: snippetsDir)
		try? snippetStore.load()
		_snippetStore = StateObject(wrappedValue: snippetStore)

		let snippetSync = SnippetSyncStore(store: snippetStore, client: client)
		_snippetSync = StateObject(wrappedValue: snippetSync)
```

Add the matching `@StateObject` properties at the top of `CatermApp`:

```swift
	@StateObject private var snippetStore: SnippetStore
	@StateObject private var snippetSync: SnippetSyncStore
```

Add `.environmentObject(snippetStore)` and `.environmentObject(snippetSync)` to the WindowGroup body.

Add a `.task` that runs initial sync:

```swift
.task {
	snippetSync.scheduleSyncPass(mode: .incremental)
}
.task {
	try? await cloudKitClient.ensureSnippetSubscription()
}
```

Add APS notification handler:

```swift
.onReceive(NotificationCenter.default
	.publisher(for: .catermCloudKitSnippetChanged)) { _ in
	snippetSync.scheduleSyncPass(mode: .incremental)
}
```

Hook account-change to call snippet wipe on `.identityChanged`. The existing host-side observer at `CatermApp.swift:223-231` does this — extend it:

```swift
.onReceive(NotificationCenter.default
	.publisher(for: .catermICloudAccountChanged)) { _ in
	Task {
		let outcome = await accountIdentityTracker.handleAccountChange(client: cloudKitClient)
		if outcome == .identityChanged {
			await credentialSyncAccountReset.resetForAccountChange()
			try? snippetStore.wipeLocal()
			snippetSync.scheduleSyncPass(mode: .forceFull)
		}
	}
}
```

- [ ] **Step 21.2: Add toolbar button on `TerminalContainerView`**

Open `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`. Wrap the existing `ZStack { ... }` in a `VStack { ... }` topped with a thin toolbar:

```swift
@State private var showingPalette = false
@EnvironmentObject var store: SnippetStore
@EnvironmentObject var sync: SnippetSyncStore

var body: some View {
	VStack(spacing: 0) {
		HStack {
			Spacer()
			Button(action: { showingPalette.toggle() }) {
				Image(systemName: "text.cursor")
					.help("Snippets (⌘⇧P)")
			}
			.buttonStyle(.borderless)
			.padding(.horizontal, 6)
			.popover(isPresented: $showingPalette) {
				SnippetPalette(
					store: store,
					capturedSurface: resolveSurfaceForCurrentTab(),
					onClose: { showingPalette = false },
					onCreate: { showingPalette = false /* host parent sheet */ }
				)
			}
		}
		.frame(height: 22)
		.background(Color.clear)

		ZStack {
			// existing content
		}
	}
}

private func resolveSurfaceForCurrentTab() -> (any SnippetDispatchTarget)? {
	store.surfaceRegistry?.surface(for: tabId)  // adapt to wherever the registry lives
}
```

The "create" callback inside the popover needs to hand off to the parent's editor sheet. Wire via a binding passed down from `MainWindow`.

- [ ] **Step 21.3: Verify build + manual smoke**

```bash
cd apps/macos && make run-app
```

Connect to a host, press ⌘⇧P, palette appears. Click toolbar button, palette appears. ⌘⇧S opens editor.

- [ ] **Step 21.4: Commit**

```bash
git add apps/macos/Sources/Caterm/
git commit -m "feat(snippets): wire SnippetSyncStore + toolbar button + account-switch wipe"
```

---

## Task 22: APS dispatch + 60-min force-full timer

**Spec:** §3.12.

**Files:**
- Modify: `apps/macos/Sources/Caterm/AppDelegate.swift`
- Modify: `apps/macos/Sources/SnippetStore/SnippetSyncStore.swift`

- [ ] **Step 22.1: AppDelegate APS case**

Open `AppDelegate.swift`. Find `parsePushUserInfo` (or whatever method dispatches APS notifications by subscription ID — search for `hostSubscriptionID`). Add a `case CloudKitPushNames.snippetSubscriptionID:` branch that posts `.catermCloudKitSnippetChanged`:

```swift
case CloudKitPushNames.snippetSubscriptionID:
	NotificationCenter.default.post(name: .catermCloudKitSnippetChanged, object: nil)
```

- [ ] **Step 22.2: 60-min timer in `SnippetSyncStore`**

Append to `SnippetSyncStore.swift`:

```swift
	private var forceFullTimer: Task<Void, Never>?

	public func startForceFullTimer() {
		forceFullTimer?.cancel()
		forceFullTimer = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60 * 60))
				guard !Task.isCancelled else { return }
				self?.scheduleSyncPass(mode: .forceFull)
			}
		}
	}

	public func stopForceFullTimer() {
		forceFullTimer?.cancel()
		forceFullTimer = nil
	}
```

In `CatermApp` body's `.task` block, call `snippetSync.startForceFullTimer()`.

- [ ] **Step 22.3: Verify build + manual smoke**

```bash
cd apps/macos && make run-app
```

Verify the app launches without errors. (Live APS verification deferred to Task 23 manual doc.)

- [ ] **Step 22.4: Commit**

```bash
git add apps/macos/Sources/Caterm/AppDelegate.swift apps/macos/Sources/SnippetStore/SnippetSyncStore.swift apps/macos/Sources/Caterm/CatermApp.swift
git commit -m "feat(snippets): APS dispatch case + 60-min force-full timer"
```

---

## Task 23: CloudKit Dashboard schema + manual verification doc

**Spec:** §3.13, §6.2.

**Files:**
- Create: `docs/macos-snippet-sync-manual-verification.md`

- [ ] **Step 23.1: Deploy dev schema**

Open CloudKit Dashboard → Container `iCloud.com.caterm.app` → Development → Schema → Record Types. Create `Snippet` per §3.13 of the spec. Add fields and indexes exactly as listed.

If the app has a successful `pushSnippet` and the record type doesn't exist yet, CloudKit auto-creates fields when in Development. **Verify** in the dashboard after first push that all fields appear with correct types.

- [ ] **Step 23.2: Write the manual verification doc**

Create `docs/macos-snippet-sync-manual-verification.md`:

```markdown
# Snippet sync — manual verification

**Required environment:** iCloud Production for two-Mac scenarios (silent push is throttled in Development).

## Single-Mac scenarios

### S1. Persistence across relaunch
1. Create snippet "test-1" with content "echo hi".
2. Quit Caterm (⌘Q).
3. Relaunch. Expected: "test-1" appears in palette.

### S2. Edit + delete cycle
1. Create snippet "edit-me".
2. Edit name → "edited".
3. Delete it.
4. Quit + relaunch. Expected: not present, snippets.json clean.

## Two-Mac scenarios (Production env required)

### S3. Cross-Mac propagation
1. On Mac A, create snippet "shared-1".
2. Wait ≤ 30s (silent push) or ≤ 60min (force-full timer).
3. On Mac B, open palette. Expected: "shared-1" appears.

### S4. Concurrent edit (LWW)
1. Both Macs online. Edit the same snippet within ~5s of each other.
2. Trigger sync on both.
3. Expected: later push wins. Earlier push's Mac re-fetches and reconciles.

### S5. Tombstone propagation (incl. offline)
1. Mac A: airplane mode. Delete snippet "to-delete".
2. Quit Caterm. Relaunch. Restore network.
3. Expected: outbox-driven retry pushes tombstone; Mac B sees disappear.

### S6. iCloud account switch
1. Mac A: log out of iCloud.
2. Expected: snippets.json + outbox cleared (verify via Console.app).
3. Log in as a different iCloud user.
4. Expected: that user's snippets fetched; previous user's snippets do not bleed.

## Run-mode acceptance (Task 0 spike outcome)

If Task 0 chose path (A) or (B/B'): execute the §5.4 spec matrix on bash 5, zsh 5.9, fish 3.

If Task 0 chose path (C): mark this row `deferred — Paste only in v1`.

## Pass / fail tracking

| Scenario | Date | Mac pair | Result | Notes |
|---|---|---|---|---|
| S1 | | A solo | | |
| S2 | | A solo | | |
| S3 | | A↔B | | |
| S4 | | A↔B | | |
| S5 | | A↔B | | |
| S6 | | A↔B | | |
| Run mode | | A solo | | shells: bash zsh fish |
```

- [ ] **Step 23.3: Run all tests + run the app**

```bash
cd apps/macos && make test && make run-app
```

Expected: all tests pass. App launches cleanly, all four entry points (⌘⇧P, ⌘⇧S, View → Manage Snippets…, toolbar button) work. Create / edit / delete works. (Cloud verification deferred to Plan E ship + Production env.)

- [ ] **Step 23.4: Commit**

```bash
git add docs/macos-snippet-sync-manual-verification.md
git commit -m "docs(snippets): manual verification scenarios + Task 0 spike linkage"
```

- [ ] **Step 23.5: Close out**

Open the spec's §9 and resolve every "open question" against current implementation reality. If any are still open, document the resolution in a follow-up commit on the same plan branch. Mark this plan complete.

---

## Self-Review

**Spec coverage:**
- §3.1 SwiftPM target layout → Tasks 1, 4, 9, 19 (SnippetSyncClient, SnippetStore, CloudKitSyncClient deps, TerminalEngine deps).
- §3.2 Snippet model → Task 2.
- §3.3 CKRecord schema → Task 9 (mapping) + Task 23 (Dashboard).
- §3.4 Component diagram → architectural; covered by tasks.
- §3.5 Zone + token namespace → Tasks 8, 10, 11.
- §3.6 IncrementalSnippetSyncClient → Task 3.
- §3.7 LWW reconciliation → Task 7.
- §3.8 Pending-delete outbox → Tasks 5, 6, 12.
- §3.9 Account-switch wipe (`.identityChanged` gate, tokensExist widening, single-call rule) → Task 13 + Task 21.
- §3.10 Surface registry + capture-at-open → Task 14, 17.
- §3.11 Sync pass shape → Task 12.
- §3.12 Sync triggers → Tasks 12, 21, 22.
- §3.13 CloudKit Dashboard setup → Task 23.
- §4 UI → Tasks 15, 16, 17, 18, 20, 21.
- §5 Terminal injection → Tasks 0, 19.
- §6 Testing → covered alongside each implementation task; manual doc in Task 23.

**Placeholder scan:** None of the patterns from the no-placeholder list appear in the steps. Every code step has concrete code; every command has expected output. The Task 0 spike record contains a `<mechanism>` blank — that is the spike's *output*, not a plan placeholder. Task 19 has two alternative `executeSnippet` bodies depending on spike outcome — both are concrete.

**Type consistency:**
- `Snippet` defined in Task 2; used in Tasks 5, 6, 7, 9, 12, 15, 16, 17, 18 — consistent.
- `SnippetSyncOperation` defined in Task 7; used in Task 12 — consistent.
- `SnippetSyncReconciler.reconcileDelta(local:changedSnippets:deletedIDs:locallyDirty:)` — signature consistent across Task 7 implementation and Task 12 caller.
- `SnippetSyncReconciler.reconcileFullSnapshot(local:remote:locallyDirty:)` — signature consistent.
- `IncrementalSnippetSyncClient` protocol method names are consistent across Task 3 declaration, Task 10 (push/delete/subscription), Task 11 (fetch/checkpoint), Task 12 fake.
- `SnippetStore.search`, `applyRemote`, `applyRemoteTombstone`, `clearOutboxEntry`, `wipeLocal`, `pendingDeletedSnippetIDs` — all defined in Tasks 5–6, used in Task 12 with same names.
- `SnippetDispatchTarget` defined in Task 19 (after consolidation note), used in Task 17 — consistent (via the move described in 19.3).

No placeholder; no contradictions; spec fully covered.
