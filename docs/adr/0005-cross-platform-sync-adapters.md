# Cross-platform sync shares behavior behind native lifecycle adapters

Status: accepted

macOS and iOS share repository contracts, reconciliation, encrypted credential
rules, snippet and settings semantics, and user-visible sync states. Platform
adapters own only lifecycle triggers and presentation: macOS responds to wake,
push, foreground scheduling, and menu actions; iOS responds to launch, scene
activation, push, and explicit refresh without promising continuous background
execution. We rejected reusing the AppKit-bound HostSyncStore directly on iOS
and rejected maintaining a second mobile merge implementation.

Consequences: cached resources stay visible during temporary account or network
failure, account changes suspend every sync lane before resetting identity-bound
state, and both platform repositories must pass the same behavioral contract.
