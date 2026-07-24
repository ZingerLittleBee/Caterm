# Keep macOS transport outside App Sandbox

Status: accepted

Caterm for macOS remains a Developer ID application protected by the hardened
runtime, without the App Sandbox entitlement. Its terminal transport is owned
by libghostty, which creates the PTY child and executes the system OpenSSH
client. A sandbox-signed Caterm prototype could launch and access its
container-scoped temporary directory, but libghostty's child failed at the
exec boundary before OpenSSH started. Enabling App Sandbox in the current
architecture would therefore disable Caterm's core terminal capability.

The desktop SFTP task continues to use explicit native file selection,
security-scoped bookmarks, unavailable-location recovery, and process reuse
through the active SSH control socket. These controls limit local file access
at the product boundary, but they do not claim that the macOS process itself
is sandboxed.

Consequences: Caterm's macOS distribution remains a notarized Developer ID
build rather than a Mac App Store build. Release verification must cover the
hardened-runtime shipping configuration. The App Sandbox entitlement must not
be added unless the PTY transport is replaced by an architecture whose child
execution model is supported inside the sandbox, such as an appropriately
embedded and signed helper, and the complete terminal and SFTP flows are
revalidated. Apple's guidance on
[protecting data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox),
[embedding a helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app),
and
[user-selected file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
defines the boundary for any future redesign.
