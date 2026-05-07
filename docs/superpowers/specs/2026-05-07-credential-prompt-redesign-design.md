# Credential Prompt Redesign

## 1. Background

`CredentialSetupView` is the SwiftUI sheet shown when the user tries to connect
to a host that has no usable local credential. The sheet currently has two
visual problems:

1. **Sheet height jumps when the user changes auth method.** `password`
   renders one `SecureField`, `key file` renders 3–4 controls, `agent`
   renders nothing. Because the sheet only fixes width
   (`.frame(width: 480)`), the auto-grown `Form` makes the modal resize
   between ~180 px and ~320 px tall as the user clicks the segmented
   control.
2. **Visual style drifts from macOS conventions.** The current sheet uses
   `Form` without `.formStyle(.grouped)` and inlines its action buttons as
   the last `Section`. The rest of the app (notably `HostFormView`)
   already follows the System Settings pattern — grouped form area on top,
   `Divider`, footer `HStack` with Cancel/Save — and that pattern matches
   Apple HIG more closely.

The sister sheet `HostFormView` already solves both problems:

- Fixed `.frame(width: 520, height: 460)`.
- Auth-fields ViewBuilder reserves `.frame(minHeight: 96, alignment: .top)`
  so flipping `credKind` doesn't shift the buttons.
- `Form { … }.formStyle(.grouped)` + `Divider` + footer button `HStack`.

We will adopt the `HostFormView` pattern in `CredentialSetupView` and
extract the duplicated auth-fields view into a single shared
`AuthMethodFields` component used by both sheets.

## 2. Goals

- Sheet height does not change when the user switches between
  `password` / `key file` / `agent`.
- Cancel/Save sit at a fixed location at the bottom of the sheet at all
  times.
- Visual treatment matches Apple Human Interface Guidelines for macOS
  modal sheets: grouped Form, segmented Picker for the 3-option
  enumeration, default and cancel keyboard shortcuts, secondary text in
  `.secondary` foreground style, no hand-rolled CSS-style coloring.
- The duplicated auth-fields ViewBuilder logic (currently appearing in
  both `CredentialSetupView` and `HostFormView.authDetails`) lives in
  exactly one place.
- Existing behavior — keychain write, error display, parent-controlled
  dismissal, key-path canonicalization — is preserved verbatim. This is
  a UX/structural redesign, not a behavior change.

## 3. Non-Goals

- No change to `CredentialSource` / `HostSecrets` / `SessionStore.setHostCredentialMaterial`.
- No change to `HostFormView.body` outside of swapping the inline auth
  ViewBuilder for the new shared component.
- No new auth methods.
- No animation tweaks beyond what `Form` does by default.
- No string changes beyond two specific cases: (a) title-case
  treatment of method labels (`password` → `Password`, `key file` →
  `Key File`, `agent` → `Agent` in the segmented control), and (b)
  `CredentialSetupView` gains the existing `HostFormView` footnotes for
  each method (e.g. "Stored in Keychain.", "Path stored locally.",
  "Caterm will use the running ssh-agent for authentication.") because
  it now uses the same shared component. No newly authored strings.

## 4. Architecture

### 4.1 New shared component: `AuthMethodFields`

```
apps/macos/Sources/Caterm/Views/AuthMethodFields.swift   (new)
```

A SwiftUI view that renders the auth-method-conditional sub-form.
Owns nothing; takes its state as bindings from the parent.

```swift
struct AuthMethodFields: View {
    @Binding var credKind: CredKind
    @Binding var keyPath: String
    @Binding var hasPassphrase: Bool
    @Binding var pendingSecret: String

    /// Tightens the password footnote when the parent already shows a
    /// `(stored in Keychain)` hint elsewhere. Defaults to true (full
    /// helper text shown).
    var showsPasswordHint: Bool = true

    var body: some View { /* see §4.4 */ }
}
```

`CredKind` is the existing 3-case enum already declared in both
`HostFormView` and `CredentialSetupView`. As part of this change it is
promoted to a top-level type:

```
apps/macos/Sources/Caterm/Views/CredKind.swift            (new)

enum CredKind: String, CaseIterable, Identifiable {
    case password
    case keyFile = "key file"
    case agent
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .keyFile:  return "Key File"
        case .agent:    return "Agent"
        }
    }
}
```

Both call sites delete their nested `enum CredKind` and import the new
top-level one.

### 4.2 Rewritten `CredentialSetupView`

The struct keeps its public surface (`host`, `onSaved`, `onCancel`,
state vars, `save()`, `browseKey()`, `canonicalizedKeyPath()`). Only
`body` and `isValid` change.

```swift
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
```

Width stays at 480 (matches the previous design); height is fixed at
360, which is enough for the largest variant (`key file` with passphrase
enabled and an inline `errorMessage` Section). The `errorMessage`
appearing/disappearing is the only allowed sheet-content change — and
since `Form` is `.scrollDisabled`, an unusually long error message
clips rather than resizing the sheet.

`browseKey()` is plumbed into `AuthMethodFields` via an `onBrowse:
() -> Void` closure rather than letting the child view present its own
`NSOpenPanel`. This keeps the file-system side effect with the parent
(closer to the call to `canonicalizedKeyPath()`) and keeps
`AuthMethodFields` purely visual.

### 4.3 `HostFormView` cutover

`HostFormView.authDetails` is replaced by an `AuthMethodFields` call:

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

`HostFormView` itself keeps its outer shell unchanged (`.frame(width:
520, height: 460)`, `populate()`, `submit()`, `buildHost(...)`). The
nested `enum CredKind` is removed; the `displayName` lookup that lived
on it now lives on the top-level enum.

### 4.4 `AuthMethodFields` body

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        switch credKind {
        case .password:
            SecureField("Password", text: $pendingSecret)
                .textContentType(.password)
            if showsPasswordHint {
                footnote("Stored in Keychain.")
            }

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
```

`showsPasswordHint` defaults to `true`. `CredentialSetupView` and
`HostFormView` both pass `true`; the parameter exists so a future caller
that already labels the password field with `"(stored in Keychain)"`
can suppress duplication. (YAGNI applies — only add new call sites if
they actually appear; do not add other knobs preemptively.)

### 4.5 Picker label visibility

`HostFormView` uses `.labelsHidden()` on the segmented Picker because
its enclosing Section already labels `Method` via `LabeledContent` in
the Connection block. `CredentialSetupView` does **not** add
`.labelsHidden()` — it wants the inline `Method` label that `Picker`
emits with a `LabelsVisibility(.automatic)` inside `.formStyle(.grouped)`,
which renders as the standard left-aligned grey label macOS users
expect.

This is the only stylistic divergence between the two sheets; the
duplication is justified because each sheet's surrounding Form context
is different.

### 4.6 What is NOT changing

- `CredentialSetupView.save()` — same Task / errorMessage / isSaving flow.
- `CredentialSetupView.canonicalizedKeyPath()` — bit-for-bit identical.
- `CredentialSetupView.browseKey()` — same `NSOpenPanel` body.
- `HostListSidebar.sheet(item: $pendingCredentialHost)` — no caller-side
  changes; `CredentialSetupView`'s init signature is preserved.
- `HostFormView.populate()`, `submit()`, `buildHost(...)`, port-clamp
  validation, theme override section.

## 5. Testing

This change is structural / visual. There are no behavior contracts to
unit-test that we don't already cover:

- `HostFormView` already has no UI tests (no snapshot framework — see
  the spec for the previous SSH connection progress feature for the
  rationale). Manual smoke is the same.
- `CredentialSetupView`'s observable behavior is unchanged: `save()` ↔
  `onSaved`, `Cancel` ↔ `onCancel`, error rendering. None of these are
  unit-tested today, and we're not adding tests as part of this change
  because the redesign is purely visual.
- A small **manual checklist** lives at
  `apps/macos/Manual/credential-prompt-checklist.md` covering: sheet
  height stable across method flips, Cancel works, Save works for each
  method, error inline rendering, keyboard shortcuts. The plan adds it
  as one of its tasks.

The full Swift test suite (`swift test`) must remain green at every
step (685 tests / 0 failures, current baseline as of the prior SSH
connection progress feature).

## 6. Migration / rollout

Single PR. No feature flag — the redesign is opt-out by reverting the
PR. Order of changes inside the PR:

1. Add `CredKind.swift` (top-level enum).
2. Add `AuthMethodFields.swift`.
3. Cut `CredentialSetupView` over to it (rewrites `body`, removes nested
   `CredKind`).
4. Cut `HostFormView` over to it (removes nested `CredKind` and the
   inlined `authDetails`).
5. Add the manual checklist file.
6. `swift test` + `swift build` + manual verification.

Steps 3 and 4 are independent — either order works — but doing 3 first
gives a more-immediately-visible UX win in case the work is paused.

## 7. Open questions

None. The design above resolves the original issue (height jumping)
and stays inside the existing visual idioms used elsewhere in the app.

## Appendix A — files touched

```
apps/macos/Sources/Caterm/Views/CredKind.swift            (new)
apps/macos/Sources/Caterm/Views/AuthMethodFields.swift    (new)
apps/macos/Sources/Caterm/Views/CredentialSetupView.swift (rewrite body, remove nested enum)
apps/macos/Sources/Caterm/Views/HostFormView.swift        (cut over to AuthMethodFields, remove nested enum)
apps/macos/Manual/credential-prompt-checklist.md          (new)
```

No other files change. `HostListSidebar.swift` is unaffected because
`CredentialSetupView`'s init signature is preserved.
