import Foundation

public protocol ProcessRunner: Sendable {
    func run(
		argv: [String],
		env: [String: String],
		workingDirectory: URL
	) async -> Int32
}

/// Non-macOS ControlMaster runner. ControlMaster relies on shelling out to
/// `/usr/bin/ssh` via `Process`, unavailable on iOS/iPadOS. Returns 127 so
/// `isAlive` reports the master as down rather than crashing.
public struct UnavailableProcessRunner: ProcessRunner {
    public init() {}
    public func run(
		argv: [String],
		env: [String: String],
		workingDirectory: URL
	) async -> Int32 { 127 }
}

#if os(macOS)
public struct SystemProcessRunner: ProcessRunner {
    public init() {}
    public func run(
		argv: [String],
		env: [String: String],
		workingDirectory: URL
	) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
			proc.currentDirectoryURL = workingDirectory
            if !env.isEmpty {
                var e = ProcessInfo.processInfo.environment
                for (k, v) in env { e[k] = v }
                proc.environment = e
            }
            proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try proc.run() } catch { cont.resume(returning: 127) }
        }
    }
}

public typealias DefaultProcessRunner = SystemProcessRunner
#else
public typealias DefaultProcessRunner = UnavailableProcessRunner
#endif

@MainActor
public final class ControlMasterManager {
    private let cacheDir: URL
    private let runner: ProcessRunner
    private var destinations: [UUID: String] = [:]

    /// Process-wide ControlMaster manager backed by a short, user-scoped
    /// temporary directory. The UI layer uses this shared instance so socket
    /// paths and liveness lookups stay consistent across views.
    /// Startup fails explicitly when the protected socket directory cannot be
    /// created because SSH sessions cannot function safely without it.
    public static let shared: ControlMasterManager = {
        do {
            return ControlMasterManager(
                cacheDir: try CacheDirectories.controlMasterDir()
            )
        } catch {
            preconditionFailure(
                "Unable to create ControlMaster directory: \(error)"
            )
        }
    }()

    public init(cacheDir: URL, runner: ProcessRunner = DefaultProcessRunner()) {
        self.cacheDir = cacheDir
        self.runner = runner
    }

    public nonisolated func socketPath(for hostId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(Self.socketToken(for: hostId)).sock")
    }

	private nonisolated static func socketToken(for hostId: UUID) -> String {
		var bytes = hostId.uuid
		return withUnsafeBytes(of: &bytes) { rawBuffer in
			Data(rawBuffer)
				.base64EncodedString()
				.replacingOccurrences(of: "+", with: "-")
				.replacingOccurrences(of: "/", with: "_")
				.replacingOccurrences(of: "=", with: "")
		}
	}

    public func register(hostId: UUID, destination: String) {
        destinations[hostId] = destination
    }

    public func isAlive(hostId: UUID) async -> Bool {
        guard let dest = destinations[hostId] else { return false }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.lastPathComponent, "-O", "check", dest]
        let code = await runner.run(
			argv: argv,
			env: [:],
			workingDirectory: cacheDir
		)
        return code == 0
    }

    public func tearDown(hostId: UUID) async {
        guard let dest = destinations[hostId] else { return }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.lastPathComponent, "-O", "exit", dest]
        _ = await runner.run(
			argv: argv,
			env: [:],
			workingDirectory: cacheDir
		)
        destinations.removeValue(forKey: hostId)
    }

    public func tearDownAll() async {
        let ids = Array(destinations.keys)
        for id in ids { await tearDown(hostId: id) }
    }
}

// `ControlMasterManager` already implements `isAlive(hostId:)` with a
// matching signature, so the conformance is empty. `@MainActor` classes
// are implicitly `Sendable`, satisfying the protocol's `Sendable`
// requirement without further annotation.
extension ControlMasterManager: ControlMasterLiveness {}
