import Foundation

public struct HostEnvironmentVariable: Codable, Hashable, Identifiable, Sendable {
	public let id: UUID
	public var name: String
	public var value: String

	public init(id: UUID = UUID(), name: String, value: String) {
		self.id = id
		self.name = name
		self.value = value
	}
}

public enum HostAutomationReviewPolicy: String, Codable, Hashable, Sendable {
	case always
	case never
}

public enum HostAutomationReconnectPolicy: String, Codable, Hashable, Sendable {
	case oncePerSession
	case everyConnection
}

public struct HostAutomation: Codable, Hashable, Sendable {
	public var isEnabled: Bool
	public var startupSnippetID: UUID?
	public var environment: [HostEnvironmentVariable]
	public var reviewPolicy: HostAutomationReviewPolicy
	public var reconnectPolicy: HostAutomationReconnectPolicy

	public static let disabled = HostAutomation()

	public init(
		isEnabled: Bool = false,
		startupSnippetID: UUID? = nil,
		environment: [HostEnvironmentVariable] = [],
		reviewPolicy: HostAutomationReviewPolicy = .always,
		reconnectPolicy: HostAutomationReconnectPolicy = .oncePerSession
	) {
		self.isEnabled = isEnabled
		self.startupSnippetID = startupSnippetID
		self.environment = environment
		self.reviewPolicy = reviewPolicy
		self.reconnectPolicy = reconnectPolicy
	}

	public var isConfigured: Bool {
		startupSnippetID != nil || !environment.isEmpty
	}

	public func validated() throws -> HostAutomation {
		if isEnabled, !isConfigured {
			throw HostAutomationValidationError.emptyConfiguration
		}

		var names: Set<String> = []
		for variable in environment {
			guard Self.isValidEnvironmentName(variable.name) else {
				throw HostAutomationValidationError.invalidEnvironmentName(variable.name)
			}
			guard names.insert(variable.name).inserted else {
				throw HostAutomationValidationError.duplicateEnvironmentName(variable.name)
			}
			guard Self.isValidEnvironmentValue(variable.value) else {
				throw HostAutomationValidationError.invalidEnvironmentValue(variable.name)
			}
		}
		return self
	}

	private static func isValidEnvironmentName(_ name: String) -> Bool {
		guard !name.isEmpty, name.utf8.count <= 128 else { return false }
		let scalars = name.unicodeScalars
		guard let first = scalars.first,
		      first == "_" || first.properties.isAlphabetic,
		      first.isASCII else {
			return false
		}
		return scalars.dropFirst().allSatisfy {
			$0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || $0.properties.numericType != nil)
		}
	}

	private static func isValidEnvironmentValue(_ value: String) -> Bool {
		guard value.utf8.count <= 4_096 else { return false }
		return value.unicodeScalars.allSatisfy {
			$0.value >= 0x20 && $0.value != 0x7F
		}
	}
}

public enum HostAutomationValidationError: Error, Equatable, Sendable {
	case emptyConfiguration
	case invalidEnvironmentName(String)
	case duplicateEnvironmentName(String)
	case invalidEnvironmentValue(String)
}

extension HostAutomationValidationError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .emptyConfiguration:
			"Choose a startup snippet or add an environment variable before enabling automation."
		case .invalidEnvironmentName(let name):
			"\(name.isEmpty ? "The environment variable name" : name) is not a valid environment variable name."
		case .duplicateEnvironmentName(let name):
			"\(name) appears more than once."
		case .invalidEnvironmentValue(let name):
			"\(name) contains an unsupported control character or is too long."
		}
	}
}
