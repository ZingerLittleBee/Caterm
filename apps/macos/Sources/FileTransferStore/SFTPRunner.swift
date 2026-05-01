import Foundation
import SFTPCommandBuilder

public protocol SFTPRunner: Sendable {
	func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32)
}

public protocol ControlMasterLiveness: Sendable {
	func isAlive(hostId: UUID) async -> Bool
}

public struct SystemSFTPRunner: SFTPRunner {
	public init() {}
	public func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Int32), Error>) in
			let proc = Process()
			proc.executableURL = URL(fileURLWithPath: inv.argv[0])
			proc.arguments = Array(inv.argv.dropFirst())
			if !inv.environment.isEmpty {
				var e = ProcessInfo.processInfo.environment
				for (k, v) in inv.environment { e[k] = v }
				proc.environment = e
			}
			let stdoutPipe = Pipe()
			let stdinPipe = Pipe()
			proc.standardOutput = stdoutPipe
			proc.standardInput = stdinPipe
			proc.standardError = stdoutPipe // merge for parsing simplicity
			proc.terminationHandler = { p in
				let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
				cont.resume(returning: (String(data: data, encoding: .utf8) ?? "", p.terminationStatus))
			}
			do {
				try proc.run()
				stdinPipe.fileHandleForWriting.write(inv.scriptStdin.data(using: .utf8) ?? Data())
				try stdinPipe.fileHandleForWriting.close()
			} catch {
				cont.resume(throwing: error)
			}
		}
	}
}
