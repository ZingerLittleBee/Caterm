import Combine
import Foundation
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Mobile host store. Backs the mobile shell with the same on-disk host
/// JSON the macOS app and CloudKit sync use (`HostPersistence`), without
/// pulling in `SessionStore`'s desktop tab/terminal/SSH-config machinery.
/// This keeps AppKit isolated while staying format-compatible with desktop.
@MainActor
public final class MobileHostStore: ObservableObject {
	public enum StoreError: Error, Equatable {
		case hostNotFound
	}

	@Published public private(set) var hosts: [SSHHost]

	private let fileURL: URL

	public init(fileURL: URL) {
		self.fileURL = fileURL
		self.hosts = (try? HostPersistence.load(from: fileURL)) ?? []
	}

	public func add(_ host: SSHHost) throws {
		hosts.append(host)
		try persist()
	}

	public func update(_ host: SSHHost) throws {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
			throw StoreError.hostNotFound
		}
		hosts[index] = host
		try persist()
	}

	public func delete(id: UUID) throws {
		hosts.removeAll { $0.id == id }
		try persist()
	}

	/// Replace the whole list and persist. The mobile shell mutates hosts
	/// through a plain `Binding<[SSHHost]>` (append/remove/replace), so a
	/// single persisting setter is the seam that keeps every UI edit on
	/// disk without threading store calls through every view.
	public func replaceAll(_ newHosts: [SSHHost]) {
		hosts = newHosts
		try? persist()
	}

	/// `Binding` view of the host list whose setter persists. Feed this to
	/// the array-based shell so all edits round-trip to the shared file.
	public var binding: Binding<[SSHHost]> {
		Binding(
			get: { self.hosts },
			set: { self.replaceAll($0) }
		)
	}

	private func persist() throws {
		try HostPersistence.save(hosts, to: fileURL)
	}
}
