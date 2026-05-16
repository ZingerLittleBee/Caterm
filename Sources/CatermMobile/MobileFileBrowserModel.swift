import FileTransferStore
import Foundation

public enum MobileFileBrowserPresentation: Equatable {
	case download(path: String)
	case confirmDelete(path: String, isDirectory: Bool)
	case rename(path: String, currentName: String)
}

public struct MobileFileBrowserModel: Equatable {
	public var path: String
	public var presentation: MobileFileBrowserPresentation?

	public init(path: String = "~", presentation: MobileFileBrowserPresentation? = nil) {
		self.path = path.isEmpty ? "~" : path
		self.presentation = presentation
	}

	public mutating func activate(_ entry: RemoteEntry) {
		let childPath = path.appendingRemotePathComponent(entry.name)
		if entry.isDirectory {
			path = childPath
			presentation = nil
		} else {
			presentation = .download(path: childPath)
		}
	}

	public mutating func goUp() {
		path = path.remoteParentPath
		presentation = nil
	}

	public mutating func requestDelete(_ entry: RemoteEntry) {
		presentation = .confirmDelete(
			path: path.appendingRemotePathComponent(entry.name),
			isDirectory: entry.isDirectory
		)
	}

	public mutating func requestRename(_ entry: RemoteEntry) {
		presentation = .rename(
			path: path.appendingRemotePathComponent(entry.name),
			currentName: entry.name
		)
	}
}

private extension String {
	func appendingRemotePathComponent(_ component: String) -> String {
		let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !trimmedComponent.isEmpty else { return self }
		switch self {
		case "~":
			return "\(self)/\(trimmedComponent)"
		case "/":
			return "/\(trimmedComponent)"
		default:
			if hasPrefix("/") {
				return "/\(trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(trimmedComponent)"
			}
			return "\(trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(trimmedComponent)"
		}
	}

	var remoteParentPath: String {
		guard self != "/", self != "~" else { return self }
		if hasPrefix("~/") {
			let suffix = String(dropFirst(2))
			guard let slashIndex = suffix.lastIndex(of: "/") else { return "~" }
			return "~/" + suffix[..<slashIndex]
		}
		let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard let slashIndex = trimmed.lastIndex(of: "/") else { return "/" }
		return "/" + trimmed[..<slashIndex]
	}
}
