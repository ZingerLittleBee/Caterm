import Foundation

@MainActor
public final class CredentialSyncPreferencesStore: ObservableObject {
    @Published public private(set) var prefs: CredentialSyncPreferences

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = CredentialSyncPreferences(defaults: defaults)
    }

    public func mutate(_ block: (inout CredentialSyncPreferences) -> Void) {
        var copy = prefs
        block(&copy)
        copy.save()
        prefs = copy
    }
}
