# Credential Prompt Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the credential-prompt sheet from resizing when the user changes auth method, by extracting the auth-fields ViewBuilder into a shared component and adopting the same fixed-frame + reserved-height pattern that `HostFormView` already uses.

**Architecture:** Promote the duplicated `enum CredKind` from inside `CredentialSetupView` and `HostFormView` to a top-level type. Extract the duplicated method-conditional ViewBuilder into a new `AuthMethodFields` SwiftUI view that takes its state via `@Binding`s. Cut both sheets over to the new component. Add a manual verification checklist.

**Tech Stack:** Swift 5+, SwiftUI (macOS 14+ target), `Form { … }.formStyle(.grouped)`, `Picker(.segmented)`, XCTest for the one new unit test.

**Spec:** `docs/superpowers/specs/2026-05-07-credential-prompt-redesign-design.md`

---

## File Structure

```
apps/macos/Sources/Caterm/Views/CredKind.swift            (new — top-level enum)
apps/macos/Sources/Caterm/Views/AuthMethodFields.swift    (new — shared ViewBuilder)
apps/macos/Sources/Caterm/Views/CredentialSetupView.swift (rewrite body, remove nested enum)
apps/macos/Sources/Caterm/Views/HostFormView.swift        (cut over to AuthMethodFields, remove nested enum)
apps/macos/Tests/CatermTests/CredKindTests.swift          (new — unit test for displayName)
apps/macos/Manual/credential-prompt-checklist.md          (new — manual verification)
```

`HostListSidebar.swift` is unchanged because `CredentialSetupView`'s init signature is preserved.

---

## Task 1: Extract `CredKind` to a top-level type

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/CredKind.swift`
- Create: `apps/macos/Tests/CatermTests/CredKindTests.swift`

This task adds the new type without touching any existing call site. Both `HostFormView` and `CredentialSetupView` continue to use their own nested `CredKind` until Tasks 3 and 4 cut them over. Swift resolves nested types first inside their enclosing struct, so the new top-level type does not collide with the still-nested ones during the transition.

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/CredKindTests.swift`. **Use TAB indentation** (project convention):

```swift
import XCTest
@testable import Caterm

final class CredKindTests: XCTestCase {
	func testAllCasesOrderAndCount() {
		XCTAssertEqual(CredKind.allCases, [.password, .keyFile, .agent])
	}

	func testDisplayNamesUseTitleCase() {
		XCTAssertEqual(
			CredKind.allCases.map(\.displayName),
			["Password", "Key File", "Agent"]
		)
	}

	func testRawValuesAreStable() {
		XCTAssertEqual(CredKind.password.rawValue, "password")
		XCTAssertEqual(CredKind.keyFile.rawValue, "key file")
		XCTAssertEqual(CredKind.agent.rawValue, "agent")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd apps/macos && swift test --filter CatermTests.CredKindTests 2>&1 | tail -10
```

Expected: build error — `CredKind` is not visible from `CatermTests` (it's currently nested inside `CredentialSetupView` and `HostFormView`, and there is no top-level `CredKind` yet).

- [ ] **Step 3: Create the top-level `CredKind`**

Create `apps/macos/Sources/Caterm/Views/CredKind.swift`. **Use TAB indentation:**

```swift
import Foundation

/// SSH credential method shared by `CredentialSetupView` (small "fill in
/// missing credential" sheet) and `HostFormView` (full add/edit sheet).
/// Owns no state of its own — both sheets bind their own `credKind`
/// value to a `Picker(selection:)` typed against this enum.
enum CredKind: String, CaseIterable, Identifiable {
	case password
	case keyFile = "key file"
	case agent

	var id: String { rawValue }

	/// User-visible label for the segmented picker. The raw values are
	/// kept lowercase for backwards compatibility (Identifiable.id is
	/// the rawValue), but every visible string uses title case.
	var displayName: String {
		switch self {
		case .password: return "Password"
		case .keyFile:  return "Key File"
		case .agent:    return "Agent"
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

```
cd apps/macos && swift test --filter CatermTests.CredKindTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Run the full suite to confirm no regression**

```
cd apps/macos && swift test 2>&1 | tail -5
```

Expected: 688 executed (685 baseline + 3 new), 12 skipped, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/CredKind.swift \
        apps/macos/Tests/CatermTests/CredKindTests.swift
git commit -m "feat(macos): extract CredKind to top-level type"
```

---

## Task 2: Add the shared `AuthMethodFields` component

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/AuthMethodFields.swift`

The new view renders the auth-method-conditional sub-form (password field, key-path picker, passphrase toggle, footnotes). It owns no state — every mutable value comes in via `@Binding`. The file-system side effect (`NSOpenPanel`) is *not* inside this view; the parent passes a `onBrowse: () -> Void` closure so this view stays purely visual.

This task introduces the file but does not wire it into either sheet yet. The build is expected to pass because the file is self-contained and depends only on `CredKind` (Task 1) and SwiftUI.

- [ ] **Step 1: Create `AuthMethodFields.swift`**

Create `apps/macos/Sources/Caterm/Views/AuthMethodFields.swift`. **Use TAB indentation:**

```swift
import SwiftUI

/// Method-conditional auth field group. Used by both `CredentialSetupView`
/// and `HostFormView`. Reserves a consistent minimum height across all
/// `CredKind` variants so that flipping the segmented picker doesn't shift
/// the parent sheet's footer buttons.
struct AuthMethodFields: View {
	@Binding var credKind: CredKind
	@Binding var keyPath: String
	@Binding var hasPassphrase: Bool
	@Binding var pendingSecret: String
	var onBrowse: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch credKind {
			case .password:
				SecureField("Password", text: $pendingSecret)
					.textContentType(.password)
				footnote("Stored in Keychain.")

			case .keyFile:
				HStack {
					TextField("Private key path", text: $keyPath)
					Button("Browse…") { onBrowse() }
				}
				Toggle("Key has passphrase", isOn: $hasPassphrase)
				if hasPassphrase {
					SecureField("Passphrase", text: $pendingSecret)
						.textContentType(.password)
				}
				footnote(
					hasPassphrase
						? "Path stored locally; passphrase stored in Keychain."
						: "Path stored locally."
				)

			case .agent:
				footnote("Caterm will use the running ssh-agent for authentication.")
			}
		}
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}
```

- [ ] **Step 2: Build to verify it compiles**

```
cd apps/macos && swift build 2>&1 | tail -10
```

Expected: `Build complete!` with no warnings introduced.

- [ ] **Step 3: Run the full test suite**

```
cd apps/macos && swift test 2>&1 | tail -5
```

Expected: 688 executed, 12 skipped, 0 failures (no regression — the new file isn't called yet).

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/AuthMethodFields.swift
git commit -m "feat(macos): add shared AuthMethodFields view"
```

---

## Task 3: Cut `CredentialSetupView` over to the new layout

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/CredentialSetupView.swift`

This is the visual fix. Three concrete changes:

1. Delete the nested `enum CredKind` declaration. The `@State var credKind: CredKind = .password` line keeps working — it now resolves to the top-level type.
2. Replace the entire `body` with a `VStack(spacing: 0) { Form { … }.formStyle(.grouped); Divider(); HStack { Cancel | Save } }` shell, exactly like `HostFormView`.
3. Inside the `Authentication` section, replace the inline `if credKind == … { … }` ViewBuilder with `AuthMethodFields(...)` and reserve `.frame(minHeight: 96, alignment: .top)`.

Helper methods `save()`, `browseKey()`, `canonicalizedKeyPath()`, `isValid` stay unchanged.

- [ ] **Step 1: Replace the file's contents**

Open `apps/macos/Sources/Caterm/Views/CredentialSetupView.swift`. Replace the entire file with:

```swift
import AppKit
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Sheet shown when the user tries to connect to a host that has no
/// usable local credential (typically a host pulled from the server on
/// a fresh device). Captures auth method + secret, then hands off to
/// the parent via `onSaved` (async throws) which performs the actual
/// Keychain + SessionStore writes. The sheet only dismisses on a
/// successful Save; failures are rendered inline via `errorMessage`.
struct CredentialSetupView: View {
	let host: SSHHost
	var onSaved: (CredentialSource, String?) async throws -> Void
	var onCancel: () -> Void

	@Environment(\.dismiss) var dismiss

	@State var credKind: CredKind = .password
	@State var keyPath: String = ""
	@State var hasPassphrase = false
	@State var pendingSecret: String = ""
	@State var errorMessage: String?
	@State var isSaving = false

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section {
					VStack(alignment: .leading, spacing: 2) {
						Text(host.name).font(.headline)
						Text("\(host.username)@\(host.hostname):\(host.port)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Section("Authentication") {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)

					AuthMethodFields(
						credKind: $credKind,
						keyPath: $keyPath,
						hasPassphrase: $hasPassphrase,
						pendingSecret: $pendingSecret,
						onBrowse: browseKey
					)
					.frame(minHeight: 96, alignment: .top)
				}

				if let errorMessage {
					Section {
						Text(errorMessage)
							.font(.caption)
							.foregroundStyle(.red)
					}
				}
			}
			.formStyle(.grouped)
			.scrollDisabled(true)

			Divider()

			HStack {
				Button("Cancel") { onCancel() }
					.keyboardShortcut(.cancelAction)
					.disabled(isSaving)
				Spacer()
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(!isValid || isSaving)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 480, height: 360)
	}

	/// Save is enabled only when the inputs are usable. For .keyFile we
	/// resolve `~` and require the file to actually exist — typing a
	/// nonexistent path keeps Save disabled (no error needed; the
	/// disabled button is the affordance). This also closes the loop
	/// where a literal `~/.ssh/...` would round-trip through Save and
	/// the next connect would still see needsCredentialSetup == true,
	/// re-popping the sheet.
	var isValid: Bool {
		switch credKind {
		case .password:
			return !pendingSecret.isEmpty
		case .keyFile:
			guard canonicalizedKeyPath() != nil else { return false }
			if hasPassphrase { return !pendingSecret.isEmpty }
			return true
		case .agent:
			return true
		}
	}

	func canonicalizedKeyPath() -> String? {
		let trimmed = keyPath.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		let expanded = (trimmed as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: expanded) else { return nil }
		return expanded
	}

	func browseKey() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
			.appendingPathComponent(".ssh")
		if panel.runModal() == .OK, let url = panel.url {
			keyPath = url.path
		}
	}

	func save() {
		let cred: CredentialSource
		let secret: String?
		switch credKind {
		case .password:
			cred = .password
			secret = pendingSecret
		case .keyFile:
			guard let path = canonicalizedKeyPath() else { return }
			cred = .keyFile(keyPath: path, hasPassphrase: hasPassphrase)
			secret = hasPassphrase ? pendingSecret : nil
		case .agent:
			cred = .agent
			secret = nil
		}

		errorMessage = nil
		isSaving = true
		Task {
			do {
				try await onSaved(cred, secret)
				// Parent is responsible for dismissing on success
				// (it owns pendingCredentialHost binding).
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					isSaving = false
				}
			}
		}
	}
}
```

- [ ] **Step 2: Build to verify it compiles**

```
cd apps/macos && swift build 2>&1 | tail -10
```

Expected: `Build complete!`. If the build complains about an ambiguous `CredKind` reference, double-check that the nested `enum CredKind` was actually removed from the file (Step 1 above replaces the entire file, so this should not happen).

- [ ] **Step 3: Run the full test suite**

```
cd apps/macos && swift test 2>&1 | tail -5
```

Expected: 688 executed, 12 skipped, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/CredentialSetupView.swift
git commit -m "feat(macos): redesign CredentialSetupView with stable frame and shared auth fields"
```

---

## Task 4: Cut `HostFormView` over to `AuthMethodFields`

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift`

Remove the nested `enum CredKind`, the inline `@ViewBuilder var authDetails`, and the private `footnote(_:)` helper. Replace the call site in the `Authentication` section. Everything else (`@State`, `populate()`, `submit()`, `buildHost(...)`, port-clamp `isValid`, theme override section, fixed `.frame(width: 520, height: 460)`) stays exactly as is.

- [ ] **Step 1: Remove the nested `CredKind` enum**

Open `apps/macos/Sources/Caterm/Views/HostFormView.swift`. Find and delete this block (around lines 30–44):

```swift
	enum CredKind: CaseIterable, Identifiable {
		case password
		case keyFile
		case agent

		var id: Self { self }

		var displayName: String {
			switch self {
			case .password: "Password"
			case .keyFile: "Key File"
			case .agent: "Agent"
			}
		}
	}
```

(Project uses tab indentation — the leading tabs above are correct.)

- [ ] **Step 2: Replace the `Authentication` section's body**

Find the `Section("Authentication") { … }` block (around lines 64–74) and replace its body so the inline `Picker` keeps working but the inline `authDetails` is swapped for the new component:

Old:
```swift
				Section("Authentication") {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)
					.labelsHidden()

					authDetails
				}
```

New:
```swift
				Section("Authentication") {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)
					.labelsHidden()

					AuthMethodFields(
						credKind: $credKind,
						keyPath: $keyPath,
						hasPassphrase: $hasPassphrase,
						pendingSecret: $pendingSecret,
						onBrowse: browseKey
					)
					.frame(minHeight: 96, alignment: .top)
				}
```

- [ ] **Step 3: Delete the `authDetails` ViewBuilder and `footnote` helper**

Find and delete the `authDetails` computed property and the `footnote(_:)` helper (around lines 105–142):

```swift
	/// Variable-content area for the chosen credential method. Reserves a
	/// consistent minimum height across all variants so that switching
	/// methods doesn't shift the buttons or other sections.
	@ViewBuilder
	private var authDetails: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch credKind {
			case .password:
				SecureField("Password", text: $pendingSecret)
					.textContentType(.password)
				footnote("Stored in Keychain.")
			case .keyFile:
				HStack {
					TextField("Private key path", text: $keyPath)
					Button("Browse…") { browseKey() }
				}
				Toggle("Key has passphrase", isOn: $hasPassphrase)
				if hasPassphrase {
					SecureField("Passphrase", text: $pendingSecret)
						.textContentType(.password)
				}
				footnote(
					hasPassphrase
						? "Path stored locally; passphrase stored in Keychain."
						: "Path stored locally."
				)
			case .agent:
				footnote("Caterm will use the running ssh-agent for authentication.")
			}
		}
		.frame(minHeight: 96, alignment: .top)
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}
```

(All deleted — `AuthMethodFields` now owns this logic.)

- [ ] **Step 4: Build to verify it compiles**

```
cd apps/macos && swift build 2>&1 | tail -10
```

Expected: `Build complete!`. If the build fails with an "ambiguous use of `CredKind`" error, the nested enum was not fully deleted in Step 1.

- [ ] **Step 5: Run the full test suite**

```
cd apps/macos && swift test 2>&1 | tail -5
```

Expected: 688 executed, 12 skipped, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostFormView.swift
git commit -m "refactor(macos): cut HostFormView over to shared AuthMethodFields"
```

---

## Task 5: Add the manual verification checklist

**Files:**
- Create: `apps/macos/Manual/credential-prompt-checklist.md`

- [ ] **Step 1: Create the checklist**

Create `apps/macos/Manual/credential-prompt-checklist.md`:

```markdown
# Credential Prompt — Manual Verification

Run after any change to `CredentialSetupView`, `HostFormView`, `AuthMethodFields`,
or `CredKind`.

Build + launch:

```
cd apps/macos && make run-app
```

## 1. Sheet height is stable across method flips
- On a fresh device or with a host whose local credential was deleted,
  click Connect on a host so the credential-prompt sheet appears.
- Click each method in turn: `Password` → `Key File` → `Agent` → `Password`.
- **Expect:** the sheet's outer frame does not move, resize, or reflow.
  The Cancel / Save buttons stay in the same position on the screen
  through every method change. Only the inner field area redraws.

## 2. Password method saves
- With the sheet open, choose `Password`. Enter a value. Click Save (or press ⏎).
- **Expect:** sheet dismisses, connection retries with the new credential.
  Re-opening the host (after wiping its credential again) shows a clean
  empty sheet — the previous secret is not pre-populated.

## 3. Key File method saves with no passphrase
- Choose `Key File`. Click `Browse…`, pick `~/.ssh/id_ed25519` (or any
  existing key). Leave `Key has passphrase` off. Click Save.
- **Expect:** sheet dismisses, connection retries.

## 4. Key File method with passphrase
- Choose `Key File`. Pick a key. Enable `Key has passphrase`. Type a
  value into the new `Passphrase` field. Click Save.
- **Expect:** sheet dismisses, connection retries. Save remains disabled
  until both the path and passphrase are non-empty.

## 5. Agent method saves
- Choose `Agent`. Click Save.
- **Expect:** sheet dismisses immediately (no secret input required).

## 6. Cancel button + ⎋
- Click Cancel. Then re-open the prompt and press the Escape key.
- **Expect:** both close the sheet without saving anything.

## 7. Error inline rendering
- Cause a save to fail (e.g., write a Keychain-blocked path or simulate
  via test hooks). Click Save.
- **Expect:** the sheet stays open and shows a red `errorMessage` line
  inside a third Section. The sheet's outer frame does not resize.

## 8. HostFormView (sister sheet) still works
- Open `Add Host` from the sidebar. Cycle through `Password` / `Key File`
  / `Agent` in the Authentication section.
- **Expect:** the form area below the picker swaps fields without
  shifting the Save button. Submit a new host and verify it appears
  in the sidebar.
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/Manual/credential-prompt-checklist.md
git commit -m "docs(macos): manual checklist for credential prompt redesign"
```

---

## Task 6: Final lint, build, full test run, and smoke

- [ ] **Step 1: Lint / format**

```
bun x ultracite check
```

Expected: no new errors beyond the four pre-existing ones in
`.superpowers/brainstorm/.../termius-style.html` (those are unrelated to
this plan and were noted in the prior SSH connection progress feature).
This plan touches only Swift files, so `ultracite` (Biome) should report
no diff against baseline.

- [ ] **Step 2: Full Swift test run**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 688 executed, 12 skipped, 0 failures.

- [ ] **Step 3: Build the app and smoke-test**

```
cd apps/macos && make run-app
```

Run scenarios 1, 2, and 8 from `apps/macos/Manual/credential-prompt-checklist.md`:

1. Click each of `Password` / `Key File` / `Agent` in the credential-prompt
   sheet — verify the sheet does not resize.
2. Save a Password credential — verify the connection retries.
8. Open `Add Host` and cycle through the three methods in the bigger sheet —
   verify the layout does not shift.

- [ ] **Step 4: No final commit needed**

This task is verification-only. If `ultracite check` reported a pre-existing
warning that was not introduced by this plan, leave it alone (the prior plan
already documented it as out of scope). Only commit if you intentionally
fixed something.

---

## Done

The redesign is complete when:

- ✅ All 6 tasks above are merged into the rio-de-janeiro branch.
- ✅ `swift test` shows 688 executed / 0 failures.
- ✅ `swift build` is clean.
- ✅ Scenarios 1, 2, and 8 in `apps/macos/Manual/credential-prompt-checklist.md`
  pass on a real macOS launch.
- ✅ The credential-prompt sheet does not resize when the user flips between
  `Password` / `Key File` / `Agent`.
- ✅ `HostFormView` continues to work as before, now sharing the same
  `AuthMethodFields` component.
