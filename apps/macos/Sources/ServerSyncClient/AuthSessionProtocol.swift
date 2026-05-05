import Foundation

/// Auth dependency surface for components that only need to observe sign-in
/// state. `HostSyncStore` consumes this so tests can inject a stub without
/// constructing a concrete client. The historical email/password
/// `AuthSession` class against better-auth was removed in Plan E — the
/// surviving conformer is `iCloudAccountSession` from `CloudKitSyncClient`.
public protocol AuthSessionProtocol: AnyObject {
    var isSignedIn: Bool { get }
}
