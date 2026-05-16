# Caterm Mobile Shell Design

## Objective

Adapt Caterm for mobile by adding a real iOS/iPadOS SwiftUI shell. Mobile
screens must use mobile interaction patterns instead of transplanting the
current macOS window, sidebar, drawer, popover, keyboard palette, and AppKit
bridges.

The approved scope is option A: build the mobile shell first and isolate the
terminal surface. A full mobile terminal port is intentionally out of phase 1.

## Current State

Caterm is currently a native macOS app:

- `Package.swift` declares only `.macOS(.v14)`.
- `Sources/Caterm/CatermApp.swift` imports AppKit, uses
  `@NSApplicationDelegateAdaptor`, AppKit command routing, and macOS windows.
- `Sources/TerminalEngine` is AppKit-backed through `GhosttySurfaceNSView` and
  `NSViewRepresentable`.
- `Sources/Caterm/Views/MainWindow.swift` is a desktop split view with an
  overlay file drawer.
- `Sources/Caterm/Views/HostListSidebar.swift` installs an `NSTableView`
  double-click bridge.
- `Sources/Caterm/Views/FileDrawerView.swift` uses desktop drag/drop,
  `NSOpenPanel`, and `NSPasteboard`.
- Several shared stores and domain modules are mostly platform-safe:
  `SSHCommandBuilder`, `SessionStore`, `SnippetStore`, `SettingsStore`,
  `CloudKitSyncClient`, `SnippetSyncClient`, and most sync/domain types.

This means mobile support needs a platform shell and targeted platform
abstractions. Narrowing the macOS window is not mobile adaptation.

## Design Principles

- Keep macOS behavior stable. Existing macOS views stay in place unless a
  shared abstraction is needed.
- Move reusable logic into platform-safe types rather than importing AppKit in
  shared code.
- Use SwiftUI navigation containers that match the device:
  `NavigationStack` for iPhone-style drill-down and `NavigationSplitView` with
  compact-column control for iPad.
- Prefer buttons, toolbars, swipe actions, confirmation dialogs, edit mode, and
  platform menus over double-click, resize drawers, keyboard-only shortcuts,
  and AppKit popovers.
- Use flexible layout. No fixed desktop sheet sizes, no required minimum
  window width, and no `scrollDisabled(true)` in mobile forms.

## Architecture

Add a mobile app shell that depends on platform-safe modules and excludes
AppKit-only targets.

Proposed module split:

- `Caterm`: existing macOS app target. Keeps AppKit app delegate, macOS
  commands, windows, `MainWindow`, and AppKit terminal surface.
- `CatermMobile`: new iOS/iPadOS app target. Owns mobile scenes and mobile
  SwiftUI views.
- Shared libraries: continue using `SessionStore`, `SSHCommandBuilder`,
  `SnippetStore`, `SnippetSyncClient`, `SettingsStore`, `SettingsSyncStore`,
  `CloudKitSyncClient`, `CredentialSyncStore`, and related model modules when
  they compile without AppKit.
- Platform adapters: introduce small protocols for any shared layer that
  currently reaches into AppKit, such as wake notifications, pasteboard,
  document picking, and URL opening.

The first implementation pass should verify which current shared targets
compile for iOS. If a shared target imports AppKit only for lifecycle
notifications or convenience APIs, extract that dependency behind an adapter
instead of duplicating business logic.

## Mobile App Flow

### Root

The mobile root presents a host-first app:

- iPhone: `NavigationStack` with hosts as the root list.
- iPad: `NavigationSplitView(preferredCompactColumn:)` where the sidebar is the
  host list and the detail column shows host details, settings, snippets, or
  file browsing.

The root should expose primary destinations through platform-native navigation,
not through a desktop menu bar. Candidate top-level areas are Hosts, Snippets,
Settings, and Sync status. If this becomes more than two primary modes on
iPhone, use a `TabView`; otherwise keep a single host-first stack to avoid
unnecessary chrome.

### Hosts

Replace the macOS sidebar interaction model:

- Single tap selects or opens a host detail screen.
- Connect is a prominent button in detail, not a double-click gesture.
- Add host lives in a toolbar plus button.
- Edit host is a toolbar action from host detail.
- Delete uses swipe action or context menu plus confirmation dialog.
- Missing credentials route to a credential setup screen using push or sheet
  presentation, depending on whether the user is continuing a connect flow.

`HostRow` should become platform-neutral SwiftUI text and symbol layout. The
AppKit-only `TruncatingLabel` remains macOS-only.

### Host Form

Mobile host editing uses:

- `NavigationStack`.
- `Form` sections.
- Toolbar cancellation and confirmation actions.
- Keyboard-aware scrolling.
- Platform file picking for key files, if key files are supported in phase 1.

The current fixed frame and disabled scrolling are desktop behavior and should
not be used in the mobile form.

### Snippets

The command-palette interaction is desktop-first. Mobile snippets should use:

- searchable snippet list;
- detail view for previewing content;
- editor sheet or push screen for create/edit;
- copy/run actions as visible buttons or toolbar/menu actions.

Keyboard shortcuts can remain available on iPad keyboards later, but cannot be
the primary mobile interaction.

### File Browser

The macOS file drawer becomes a mobile drill-down browser:

- folder rows push into child path views;
- toolbar actions cover refresh, new folder, bookmark, and upload/download
  affordances;
- destructive actions use confirmation dialogs;
- no resizable drawer, no desktop drag target, no `NSOpenPanel`.

Phase 1 may disable upload/download if platform-safe file import/export is not
ready, but the UI should make the limitation explicit and keep the navigation
model mobile-native.

### Terminal

The existing terminal is `GhosttySurfaceNSView` and cannot render on iOS.

Phase 1 isolates this with a mobile terminal placeholder or connection detail
screen. It must not pretend to be a functioning terminal. The placeholder
should explain that terminal rendering is not available in this phase and keep
the rest of the mobile app usable.

A later full terminal port needs a separate design for libghostty rendering,
input, clipboard, URL handling, IME, gestures, and mobile keyboard behavior.

## Data Flow

- `SessionStore` remains the source of truth for hosts where platform-safe.
- Mobile views receive stores through environment or explicit initializer
  injection, matching existing SwiftUI patterns.
- Mobile-specific navigation state stays in mobile views or small
  mobile-focused coordinators.
- Sync state is displayed through existing sync stores, but any AppKit lifecycle
  observation must move behind a platform adapter.

## Error Handling

- User-facing errors use SwiftUI `alert` or `ContentUnavailableView`, not
  console-only logging.
- Destructive host/file/snippet operations require confirmation where accidental
  activation is plausible.
- Unsupported phase-1 features, especially terminal rendering and possibly file
  transfer, should be explicit states instead of hidden disabled controls.

## Accessibility And UX

- Tappable rows use `NavigationLink` or `Button`, not `onTapGesture`, unless a
  location-specific gesture is required.
- Rows combine related labels for VoiceOver where appropriate.
- Forms use standard labels and system text styles.
- Toolbar buttons use clear labels or SF Symbols with accessibility labels.
- Dynamic Type must be allowed to grow inside forms and lists.
- Mobile list selection follows platform expectations. Persistent multi-row
  selection requires edit mode on iOS/iPadOS.

## Testing And Verification

Implementation is not complete until these checks have real evidence:

- Existing macOS build still succeeds.
- New shared abstractions have focused unit tests.
- Mobile routing and form validation logic have unit tests where practical.
- Any target added to `Package.swift` compiles for its declared platform.
- If a simulator build is available from the chosen project structure, run it.
- If simulator build is not available through SwiftPM alone, document the exact
  blocker and verify every compilable target with the available commands.

## Non-Goals

- Do not port the full Ghostty terminal surface in phase 1.
- Do not rewrite the macOS app shell.
- Do not replace working sync state machines unless a platform boundary makes
  extraction necessary.
- Do not add new third-party dependencies without separate approval.

## References

- Apple SwiftUI navigation migration guidance: use `NavigationStack` and
  `NavigationSplitView` instead of deprecated navigation views.
- Apple `NavigationSplitView` guidance: split views collapse in compact
  contexts and support `preferredCompactColumn`.
- Apple Human Interface Guidelines for lists and tables: iOS/iPadOS selection
  and edit interactions differ from macOS.
- Apple Human Interface Guidelines for menus: iOS/iPadOS menus and context
  interactions have platform-specific layouts and expectations.
