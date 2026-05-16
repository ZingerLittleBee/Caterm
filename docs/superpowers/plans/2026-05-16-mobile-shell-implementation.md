# Mobile Shell Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real mobile-first SwiftUI shell target for iOS/iPadOS-oriented Caterm workflows while leaving the existing macOS app and AppKit terminal surface intact.

**Architecture:** Introduce a new `CatermMobile` Swift package library target that owns mobile SwiftUI views and small view models. Keep desktop-only code in `Caterm` and `TerminalEngine`; share only platform-safe domain modules. Phase 1 includes a terminal placeholder rather than a Ghostty mobile renderer.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Package Manager, XCTest, existing Caterm store/model modules.

---

## File Structure

- Modify `Package.swift`
  - Add `.iOS(.v17)` to package platforms.
  - Add library product `CatermMobile`.
  - Add target `CatermMobile`.
  - Add test target `CatermMobileTests`.
- Create `Sources/CatermMobile/MobileHostDraft.swift`
  - Platform-safe host form state, validation, and `SSHHost` construction.
- Create `Sources/CatermMobile/MobileHostActions.swift`
  - Pure mobile routing decisions for connect, edit, delete, credentials, and terminal placeholder.
- Create `Sources/CatermMobile/MobileSnippetActions.swift`
  - Pure snippet action/routing decisions for list/detail/editor/copy/run availability.
- Create `Sources/CatermMobile/MobileFileBrowserModel.swift`
  - Pure path navigation and file action state for mobile drill-down file browsing.
- Create `Sources/CatermMobile/MobileCatermShell.swift`
  - Mobile root view using `NavigationSplitView(preferredCompactColumn:)`.
- Create `Sources/CatermMobile/MobileHostsView.swift`
  - Mobile hosts list, host detail, host form, and terminal placeholder.
- Create `Sources/CatermMobile/MobileSnippetsView.swift`
  - Mobile snippets list/detail/editor flow.
- Create `Sources/CatermMobile/MobileFileBrowserView.swift`
  - Mobile drill-down remote file browser using `NavigationStack`.
- Create `Sources/CatermMobile/MobileSettingsView.swift`
  - Mobile settings/sync placeholder view for phase 1.
- Create `Tests/CatermMobileTests/MobileHostDraftTests.swift`
  - TDD tests for host validation and host construction.
- Create `Tests/CatermMobileTests/MobileHostActionsTests.swift`
  - TDD tests for connect/delete/edit route decisions.
- Create `Tests/CatermMobileTests/MobileSnippetActionsTests.swift`
  - TDD tests for snippet route/action availability.
- Create `Tests/CatermMobileTests/MobileFileBrowserModelTests.swift`
  - TDD tests for path navigation and file actions.

## Chunk 1: Package Skeleton And Host Draft

### Task 1: Add Mobile Target Skeleton

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CatermMobile/MobileHostDraft.swift`
- Test: `Tests/CatermMobileTests/MobileHostDraftTests.swift`

- [ ] **Step 1: Write failing package/host draft tests**

Create `Tests/CatermMobileTests/MobileHostDraftTests.swift`:

```swift
import XCTest
import SSHCommandBuilder
@testable import CatermMobile

final class MobileHostDraftTests: XCTestCase {
	func testPasswordDraftBuildsHostAndSecret() throws {
		var draft = MobileHostDraft()
		draft.label = "Prod"
		draft.hostname = "example.com"
		draft.port = "2222"
		draft.username = "deploy"
		draft.credential = .password(secret: "pw")

		let payload = try draft.build(mode: .add, allHosts: [])

		XCTAssertEqual(payload.host.name, "Prod")
		XCTAssertEqual(payload.host.hostname, "example.com")
		XCTAssertEqual(payload.host.port, 2222)
		XCTAssertEqual(payload.host.username, "deploy")
		XCTAssertEqual(payload.host.credential, .password)
		XCTAssertEqual(payload.secret, "pw")
	}

	func testBlankLabelFallsBackToUserAtHost() throws {
		var draft = MobileHostDraft()
		draft.hostname = "box.local"
		draft.port = "22"
		draft.username = "root"
		draft.credential = .agent

		let payload = try draft.build(mode: .add, allHosts: [])

		XCTAssertEqual(payload.host.name, "root@box.local")
		XCTAssertNil(payload.secret)
	}

	func testInvalidPortThrows() {
		var draft = MobileHostDraft()
		draft.hostname = "box.local"
		draft.port = "70000"
		draft.username = "root"

		XCTAssertThrowsError(try draft.build(mode: .add, allHosts: [])) { error in
			XCTAssertEqual(error as? MobileHostDraft.ValidationError, .invalidPort)
		}
	}
}
```

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter MobileHostDraftTests`

Expected: fail because `CatermMobile` target and `MobileHostDraft` do not exist.

- [ ] **Step 3: Add package target and minimal implementation**

Modify `Package.swift`:

- Change platforms to `[.macOS(.v14), .iOS(.v17)]`.
- Add `.library(name: "CatermMobile", targets: ["CatermMobile"])`.
- Add target:
  - name `CatermMobile`
  - dependencies `SSHCommandBuilder`, `SessionStore`, `SnippetStore`, `SnippetSyncClient`, `FileTransferStore`
  - path `Sources/CatermMobile`
- Add test target:
  - name `CatermMobileTests`
  - dependencies `CatermMobile`, `SSHCommandBuilder`, `SessionStore`, `SnippetStore`, `SnippetSyncClient`, `FileTransferStore`
  - path `Tests/CatermMobileTests`

Create `Sources/CatermMobile/MobileHostDraft.swift` with a public draft type,
credential enum, validation errors, and `build(mode:allHosts:)`.

- [ ] **Step 4: Run test and verify GREEN**

Run: `swift test --filter MobileHostDraftTests`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CatermMobile/MobileHostDraft.swift Tests/CatermMobileTests/MobileHostDraftTests.swift
git commit -m "feat(mobile): add host draft model"
```

## Chunk 2: Mobile Routing Models

### Task 2: Add Mobile Host Route Decisions

**Files:**
- Create: `Sources/CatermMobile/MobileHostActions.swift`
- Test: `Tests/CatermMobileTests/MobileHostActionsTests.swift`

- [ ] **Step 1: Write failing tests**

Test that locked hosts route to credential setup, unlocked hosts route to
terminal placeholder, delete routes through confirmation, and edit uses a form
route.

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter MobileHostActionsTests`

Expected: fail because types do not exist.

- [ ] **Step 3: Implement minimal route model**

Create enums such as:

```swift
public enum MobileHostRoute: Equatable {
	case detail(UUID)
	case edit(UUID)
	case credentialSetup(UUID)
	case terminalPlaceholder(UUID)
}

public enum MobileHostDestructiveAction: Equatable {
	case confirmDelete(UUID)
}
```

Add pure functions that take `SSHHost` and a `needsCredentialSetup` boolean.

- [ ] **Step 4: Run test and verify GREEN**

Run: `swift test --filter MobileHostActionsTests`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobile/MobileHostActions.swift Tests/CatermMobileTests/MobileHostActionsTests.swift
git commit -m "feat(mobile): add host routing decisions"
```

### Task 3: Add Snippet And File Browser Models

**Files:**
- Create: `Sources/CatermMobile/MobileSnippetActions.swift`
- Create: `Sources/CatermMobile/MobileFileBrowserModel.swift`
- Test: `Tests/CatermMobileTests/MobileSnippetActionsTests.swift`
- Test: `Tests/CatermMobileTests/MobileFileBrowserModelTests.swift`

- [ ] **Step 1: Write failing tests**

Cover:

- snippet copy is always available for nonempty content;
- run routes to terminal placeholder when no dispatch target exists;
- folder activation appends child paths;
- `goUp` preserves `~` and `/` roots;
- delete/rename file actions require confirmation or sheet state.

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter 'MobileSnippetActionsTests|MobileFileBrowserModelTests'`

Expected: fail because types do not exist.

- [ ] **Step 3: Implement minimal pure models**

Implement `MobileSnippetAction`, `MobileSnippetRoute`, and
`MobileFileBrowserModel` without SwiftUI dependencies where possible.

- [ ] **Step 4: Run test and verify GREEN**

Run: `swift test --filter 'MobileSnippetActionsTests|MobileFileBrowserModelTests'`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CatermMobile/MobileSnippetActions.swift Sources/CatermMobile/MobileFileBrowserModel.swift Tests/CatermMobileTests/MobileSnippetActionsTests.swift Tests/CatermMobileTests/MobileFileBrowserModelTests.swift
git commit -m "feat(mobile): add snippet and file browser models"
```

## Chunk 3: Mobile SwiftUI Shell

### Task 4: Add Mobile Root And Hosts UI

**Files:**
- Create: `Sources/CatermMobile/MobileCatermShell.swift`
- Create: `Sources/CatermMobile/MobileHostsView.swift`

- [ ] **Step 1: Add compile-first SwiftUI views**

Create `MobileCatermShell` with:

- `NavigationSplitView(preferredCompactColumn:)`;
- sidebar list for primary areas;
- hosts detail as default;
- terminal placeholder destination.

Create host list/detail/form views:

- list rows use `NavigationLink`;
- connect button routes to credential setup or terminal placeholder;
- edit and delete live in toolbar/swipe actions;
- form uses `NavigationStack`, `Form`, and toolbar cancel/save actions;
- no AppKit imports, fixed desktop frames, or double-click handling.

- [ ] **Step 2: Build target**

Run: `swift build --target CatermMobile`

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/CatermMobile/MobileCatermShell.swift Sources/CatermMobile/MobileHostsView.swift
git commit -m "feat(mobile): add hosts shell"
```

### Task 5: Add Mobile Snippets, Files, Settings, Terminal Placeholder UI

**Files:**
- Create: `Sources/CatermMobile/MobileSnippetsView.swift`
- Create: `Sources/CatermMobile/MobileFileBrowserView.swift`
- Create: `Sources/CatermMobile/MobileSettingsView.swift`

- [ ] **Step 1: Add SwiftUI views**

Implement:

- searchable snippet list with detail/editor affordances;
- mobile file browser drill-down with folder push navigation;
- settings/sync placeholder area;
- explicit terminal placeholder that states phase-1 terminal rendering is not
  available.

- [ ] **Step 2: Build target**

Run: `swift build --target CatermMobile`

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/CatermMobile/MobileSnippetsView.swift Sources/CatermMobile/MobileFileBrowserView.swift Sources/CatermMobile/MobileSettingsView.swift
git commit -m "feat(mobile): add secondary mobile surfaces"
```

## Chunk 4: Verification And Completion Audit

### Task 6: Run Focused And Full Verification

**Files:**
- Inspect: `Package.swift`
- Inspect: `Sources/CatermMobile/**`
- Inspect: `Tests/CatermMobileTests/**`

- [ ] **Step 1: Run focused mobile tests**

Run: `swift test --filter CatermMobileTests`

Expected: all mobile tests pass.

- [ ] **Step 2: Build mobile target**

Run: `swift build --target CatermMobile`

Expected: build succeeds.

- [ ] **Step 3: Run existing repo test command**

Run: `make test`

Expected: suite passes. Existing skipped Docker/CloudKit-token tests may remain
skipped; no new failures.

- [ ] **Step 4: Audit requirements against spec**

Check:

- package exposes a mobile shell target;
- mobile flows use SwiftUI mobile navigation;
- AppKit-only terminal remains isolated;
- no macOS UI regression files were unnecessarily rewritten;
- phase-1 limitations are visible in UI;
- tests cover new pure mobile decisions.

- [ ] **Step 5: Final commit if needed**

Commit any verification-only docs or cleanup separately.
