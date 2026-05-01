import HostSyncStore
import SwiftUI

/// Sidebar bottom row showing sync status. Reads `HostSyncStore` and
/// `SyncPreferences` from `@EnvironmentObject` (injected at the WindowGroup
/// level in `CatermApp`). Tap routing splits direct-sheet (.signedOut /
/// .failing(.auth)) from popover (.healthy / .failing(.other) / .syncing)
/// per `tapAction(for:)`.
struct SyncStatusRow: View {
    @EnvironmentObject var syncStore: HostSyncStore
    @EnvironmentObject var preferences: SyncPreferences

    @State private var popoverPresented = false
    @State private var popoverAutoCloseTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = syncIndicatorState(
                now: context.date,
                isSignedIn: syncStore.isSignedIn,
                isSyncing: syncStore.isSyncing,
                lastSyncedAt: syncStore.lastSyncedAt,
                lastSyncAttemptedAt: syncStore.lastSyncAttemptedAt,
                lastSyncErrorKind: syncStore.lastSyncErrorKind,
                failingSince: syncStore.failingSince,
                periodicSyncEnabled: preferences.periodicSyncEnabled,
                failingThreshold: syncStore.periodicInterval
            )
            statusRowBody(state: state, now: context.date)
        }
    }

    @ViewBuilder
    private func statusRowBody(state: SyncIndicatorState, now: Date) -> some View {
        Button(action: { handleTap(state: state) }) {
            HStack(spacing: 8) {
                stateIcon(state)
                stateLabel(state, now: now)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                stateChevron(state)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .accessibilityLabel(accessibilityLabel(for: state, now: now))
        .popover(isPresented: $popoverPresented,
                 arrowEdge: .trailing) {
            popoverContent(state: state, now: now)
        }
    }

    private func handleTap(state: SyncIndicatorState) {
        switch tapAction(for: state) {
        case .openSettings:
            popoverPresented = false
            NotificationCenter.default.post(
                name: .catermOpenSyncSettings, object: nil)
        case .togglePopover:
            popoverPresented.toggle()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func stateIcon(_ state: SyncIndicatorState) -> some View {
        switch state {
        case .signedOut:
            Image(systemName: "arrow.up.right.circle")
                .foregroundStyle(.tint)
        case .syncing:
            ProgressView().controlSize(.small)
        case .failing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .healthy:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: SyncIndicatorState, now: Date) -> some View {
        switch state {
        case .signedOut:
            Text("Sign in to sync")
                .foregroundStyle(.tint).font(.caption)
        case .syncing:
            Text("Syncing…")
                .foregroundStyle(.secondary).font(.caption)
        case .failing(reason: .auth, since: _):
            Text("Sign in again")
                .foregroundStyle(.red).font(.caption)
        case .failing(reason: .other, since: let since):
            Text("Sync failed · \(formatRelativeShort(since: since, now: now))")
                .foregroundStyle(.red).font(.caption)
        case .healthy(let lastSyncedAt):
            Text(formatLastSynced(lastSyncedAt, now: now))
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder
    private func stateChevron(_ state: SyncIndicatorState) -> some View {
        switch state {
        case .healthy, .failing(reason: .other, since: _):
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    // MARK: - Popover content

    @ViewBuilder
    private func popoverContent(state: SyncIndicatorState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .healthy(let lastSyncedAt):
                Label(formatLastSynced(lastSyncedAt, now: now),
                      systemImage: "checkmark.circle")
                Text("Next sync \(formatNextSyncIn(syncStore: syncStore, now: now))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Sync Now") { triggerSync() }
                    .disabled(syncStore.isSyncing)

            case .failing(reason: .other, since: let since):
                Label("Last attempt failed \(formatRelativeShort(since: since, now: now)) ago",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if let kind = syncStore.lastSyncErrorKind {
                    Text("Most recent error: \(describe(errorKind: kind))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Button("Try Again") { triggerSync() }
                    .disabled(syncStore.isSyncing)
                Button("Open Settings") {
                    popoverPresented = false
                    NotificationCenter.default.post(
                        name: .catermOpenSyncSettings, object: nil)
                }

            case .syncing:
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)

            case .signedOut, .failing(reason: .auth, since: _):
                // Should never render — these states route directly to the
                // settings sheet via handleTap. Keep an EmptyView fallback in
                // case a state transition lands here mid-render.
                EmptyView()
            }
        }
        .padding(14)
        .frame(minWidth: 240)
    }

    private func triggerSync() {
        popoverAutoCloseTask?.cancel()
        Task { @MainActor in
            try? await syncStore.sync()
            popoverAutoCloseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { popoverPresented = false }
            }
        }
    }

    // MARK: - Accessibility

    private func accessibilityLabel(for state: SyncIndicatorState, now: Date) -> String {
        switch state {
        case .signedOut:
            return "Sync sign in required, button"
        case .syncing:
            return "Sync in progress"
        case .failing(reason: .auth, since: _):
            return "Sync sign in required, button"
        case .failing(reason: .other, since: let since):
            return "Sync failed \(formatRelativeShort(since: since, now: now)) ago, button"
        case .healthy(let lastSyncedAt):
            return formatLastSynced(lastSyncedAt, now: now) + ", button"
        }
    }
}

// MARK: - Free formatters (testable without a view harness)

/// "Synced 2m ago" / "Synced just now" / "Never synced" — short relative form.
public func formatLastSynced(_ lastSyncedAt: Date?, now: Date) -> String {
    guard let lastSyncedAt else { return "Never synced" }
    let elapsed = now.timeIntervalSince(lastSyncedAt)
    if elapsed < 60 { return "Synced just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: now))"
}

/// "8m" / "1h" — short interval used in "Sync failed · 8m" suffix.
public func formatRelativeShort(since: Date, now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(since))
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
    return "\(Int(elapsed / 3600))h"
}

/// "13m" / "soon" — short interval to the next periodic sync. Renders "soon"
/// if `lastSyncedAt` is nil (fresh user) or the computed next-sync time has
/// already passed (overdue periodic cycle).
@MainActor
public func formatNextSyncIn(syncStore: HostSyncStore, now: Date) -> String {
    guard let lastSyncedAt = syncStore.lastSyncedAt else { return "soon" }
    let nextSync = lastSyncedAt.addingTimeInterval(syncStore.periodicInterval)
    let remaining = nextSync.timeIntervalSince(now)
    if remaining <= 0 { return "soon" }
    if remaining < 60 { return "in \(Int(remaining))s" }
    return "in \(Int(remaining / 60))m"
}

/// "Authentication required" / "Network or server error" — describes a
/// `SyncErrorKind` for popover display.
public func describe(errorKind: SyncErrorKind) -> String {
    switch errorKind {
    case .auth:  return "Authentication required"
    case .other: return "Network or server error"
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by `SyncStatusRow` (and any future caller) to ask `CatermApp` to
    /// flip its `@State showSyncSettings = true`. Matches the existing
    /// `.catermAddHost` / `.catermNewWindow` pattern.
    static let catermOpenSyncSettings =
        Notification.Name("CatermOpenSyncSettingsNotification")
}
