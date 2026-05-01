import Foundation

public protocol ProcessRunner: Sendable {
    func run(argv: [String], env: [String: String]) async -> Int32
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}
    public func run(argv: [String], env: [String: String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
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

@MainActor
public final class ControlMasterManager {
    private let cacheDir: URL
    private let runner: ProcessRunner
    private var destinations: [UUID: String] = [:]

    public init(cacheDir: URL, runner: ProcessRunner = SystemProcessRunner()) {
        self.cacheDir = cacheDir
        self.runner = runner
    }

    public func socketPath(for hostId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(hostId.uuidString).sock")
    }

    public func register(hostId: UUID, destination: String) {
        destinations[hostId] = destination
    }

    public func isAlive(hostId: UUID) async -> Bool {
        guard let dest = destinations[hostId] else { return false }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.path, "-O", "check", dest]
        let code = await runner.run(argv: argv, env: [:])
        return code == 0
    }

    public func tearDown(hostId: UUID) async {
        guard let dest = destinations[hostId] else { return }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.path, "-O", "exit", dest]
        _ = await runner.run(argv: argv, env: [:])
        destinations.removeValue(forKey: hostId)
    }

    public func tearDownAll() async {
        let ids = Array(destinations.keys)
        for id in ids { await tearDown(hostId: id) }
    }
}
