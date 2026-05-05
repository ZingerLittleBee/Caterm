import SwiftUI
import SessionStore

/// Popover that lists, adds, and reorders the current host's remote-path
/// bookmarks. Used by `FileDrawerView`'s path bar.
///
/// Behavior:
/// - "Add current" is disabled when the file drawer's current path is empty,
///   when the host is quarantined (newer-schema file on disk), or when
///   `normalizeRemotePath(currentPath)` already exists in the list.
/// - Clicking a bookmark navigates the file drawer to that path verbatim.
/// - The trash icon removes a bookmark; rows can be reordered by drag.
/// - When quarantined, the entire UI is read-only and a banner explains why.
@MainActor
struct RemoteBookmarkPopover: View {
	let hostId: UUID
	let currentPath: String
	let onPick: (String) -> Void
	@EnvironmentObject var store: RemoteBookmarkStore
	@Binding var isPresented: Bool

	private var bookmarks: [RemoteBookmark] { store.bookmarks(for: hostId) }
	private var isQuarantined: Bool { store.isQuarantined(for: hostId) }

	private var canAddCurrent: Bool {
		guard !isQuarantined else { return false }
		let trimmed = currentPath.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return false }
		let key = normalizeRemotePath(trimmed)
		return !bookmarks.contains { normalizeRemotePath($0.path) == key }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Bookmarks").font(.headline)
				Spacer()
				Button {
					addCurrent()
				} label: {
					Label("Add Current", systemImage: "plus")
				}
				.buttonStyle(.borderless)
				.disabled(!canAddCurrent)
				.help(addCurrentHelp)
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 8)

			Divider()

			if isQuarantined {
				quarantineBanner
			} else if bookmarks.isEmpty {
				emptyState
			} else {
				bookmarkList
			}
		}
		.frame(width: 320, height: 320)
	}

	// MARK: - Subviews

	private var quarantineBanner: some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Bookmarks unavailable", systemImage: "exclamationmark.triangle")
				.font(.headline)
			Text("This host's bookmarks file was written by a newer version of Caterm. To avoid losing data, the file is read-only until you move it aside.")
				.font(.callout)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "bookmark")
				.font(.system(size: 32))
				.foregroundColor(.secondary)
			Text("No bookmarks yet")
				.foregroundColor(.secondary)
			Text("Click \"Add Current\" to save \(currentPath.isEmpty ? "the current path" : currentPath).")
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 16)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var bookmarkList: some View {
		List {
			ForEach(bookmarks) { bm in
				HStack(spacing: 8) {
					Image(systemName: "bookmark.fill")
						.foregroundColor(.accentColor)
					VStack(alignment: .leading, spacing: 2) {
						Text(bm.label)
							.lineLimit(1)
						Text(bm.path)
							.font(.caption)
							.foregroundColor(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
					Spacer()
					Button {
						store.remove(id: bm.id, for: hostId)
					} label: {
						Image(systemName: "trash")
							.foregroundColor(.secondary)
					}
					.buttonStyle(.borderless)
					.help("Remove bookmark")
				}
				.contentShape(Rectangle())
				.onTapGesture {
					onPick(bm.path)
					isPresented = false
				}
			}
			.onMove { source, destination in
				guard let from = source.first else { return }
				store.move(from: from, to: destination, for: hostId)
			}
		}
		.listStyle(.plain)
	}

	// MARK: - Actions

	private func addCurrent() {
		let trimmed = currentPath.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let label = defaultLabel(for: trimmed)
		let bookmark = RemoteBookmark(label: label, path: trimmed)
		_ = store.add(bookmark, for: hostId)
	}

	private func defaultLabel(for path: String) -> String {
		if path == "~" { return "Home" }
		if path == "/" { return "Root" }
		let last = (path as NSString).lastPathComponent
		return last.isEmpty ? path : last
	}

	private var addCurrentHelp: String {
		if isQuarantined {
			return "Bookmarks are read-only while the file is in quarantine"
		}
		if currentPath.trimmingCharacters(in: .whitespaces).isEmpty {
			return "Navigate to a path first"
		}
		if !canAddCurrent {
			return "This path is already bookmarked"
		}
		return "Save \(currentPath) as a bookmark"
	}
}
