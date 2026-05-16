import SettingsSyncStore

// `iCloudAccountSession` is `@MainActor`-isolated, but the
// `AccountSessionProviding` protocol's requirements (`isSignedIn`,
// `refresh()`) are nonisolated. Mark the conformance `@MainActor` so the
// witnesses run on the main actor — which is where `SettingsSyncStore`
// already calls them from (`SettingsSyncStore` itself is `@MainActor`).
// Without this annotation Swift 6 mode would flag the conformance as a
// data-race hazard.
extension iCloudAccountSession: @MainActor AccountSessionProviding {}
