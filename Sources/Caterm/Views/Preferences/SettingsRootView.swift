import SwiftUI

/// Root of the Settings window: System Settings-style sidebar navigation.
/// The sidebar groups sections by domain (app-local configuration vs the
/// sync/portability surface); the detail column renders one grouped-form
/// page per section.
struct SettingsRootView: View {
  @ObservedObject var model: SettingsWindowModel

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: $model.selection) {
        Section {
          ForEach([SettingsSection.terminal, .themes]) { section in
            SettingsSidebarLabel(section: section)
          }
        }
        Section("Sync & Data") {
          ForEach([SettingsSection.cloudSync, .credentials, .backup]) { section in
            SettingsSidebarLabel(section: section)
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 185, ideal: 195, max: 240)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      detail(for: model.selection)
        .navigationTitle(model.selection.title)
        .frame(minWidth: 520, minHeight: 480)
    }
    .navigationSplitViewStyle(.balanced)
  }

  @ViewBuilder
  private func detail(for section: SettingsSection) -> some View {
    switch section {
    case .terminal:
      TerminalSettingsView(syncPreferences: model.syncEnvironment?.preferences)
    case .themes:
      ThemePickerView()
    case .cloudSync:
      if let env = model.syncEnvironment {
        CloudSyncSettingsView(
          authSession: env.authSession,
          syncStore: env.syncStore,
          preferences: env.preferences
        )
      } else {
        SyncUnavailableView()
      }
    case .credentials:
      if let env = model.syncEnvironment {
        CredentialsSettingsView(
          preferences: env.preferences,
          credentialSync: env.credentialSync,
          credentialSyncCoordinator: env.credentialSyncCoordinator,
          sessionStore: env.sessionStore,
          triggerSync: { [weak syncStore = env.syncStore] in syncStore?.syncIfSignedIn() }
        )
      } else {
        SyncUnavailableView()
      }
    case .backup:
      if let env = model.syncEnvironment,
        let sessionStore = env.sessionStore
      {
        BackupSettingsView(
          sessionStore: sessionStore,
          snippetStore: env.snippetStore,
          bookmarkStore: env.bookmarkStore
        )
      } else {
        SyncUnavailableView()
      }
    }
  }
}

/// Sidebar row: colored rounded-rect icon tile + title, mirroring the
/// System Settings sidebar visual language.
private struct SettingsSidebarLabel: View {
  let section: SettingsSection

  var body: some View {
    Label {
      Text(section.title)
    } icon: {
      Image(systemName: section.systemImage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(section.iconColor.gradient, in: .rect(cornerRadius: 5))
    }
    .tag(section)
  }
}

/// Detail placeholder while the sync stack hasn't been injected yet
/// (early app boot, or unit tests constructing a bare window controller).
struct SyncUnavailableView: View {
  var body: some View {
    ContentUnavailableView(
      "Sync Is Starting Up",
      systemImage: "icloud",
      description: Text("Sync settings become available once the app finishes launching.")
    )
  }
}
