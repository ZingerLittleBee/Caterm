import Foundation

public enum CacheDirectories {
    /// Returns ~/Library/Caches/Caterm/cm/, creating it with mode 0700 if needed.
    /// `root` parameter exists for tests; production callers omit it.
    public static func controlMasterDir(root: URL? = nil) throws -> URL {
        let base = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm")
        let cm = base.appendingPathComponent("cm")
        try FileManager.default.createDirectory(
            at: cm,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return cm
    }
}
