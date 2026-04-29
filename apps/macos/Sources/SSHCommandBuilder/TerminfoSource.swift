import Foundation

/// Loads the bundled `xterm-ghostty.terminfo` resource shipped with the
/// `SSHCommandBuilder` SwiftPM target.
///
/// The resource is a manual snapshot of Ghostty's terminfo source — see
/// `Resources/README.md` for the regen workflow and the upstream pin.
///
/// Returns `nil` only when the resource is missing from the built bundle,
/// which would indicate a build / packaging error. The
/// `TerminfoSourceTests` suite is a CI gate against shipping such a build.
enum TerminfoSource {
    /// Cached at first call; the bundle resource never changes for the
    /// lifetime of the process.
    private static let cached: String? = {
        guard let url = Bundle.module.url(
            forResource: "xterm-ghostty",
            withExtension: "terminfo"
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static func terminfoDump() -> String? {
        cached
    }
}
