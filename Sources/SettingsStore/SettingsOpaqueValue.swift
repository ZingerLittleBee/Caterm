import Foundation

/// Property-list value retained by clients that do not understand a newer
/// settings field yet. Keeping the original shape prevents an older device
/// from erasing platform-specific or future settings during a sync round trip.
public enum SettingsOpaqueValue: Codable, Equatable, Sendable {
	case string(String)
	case integer(Int)
	case double(Double)
	case bool(Bool)
	case data(Data)
	case date(Date)
	case array([SettingsOpaqueValue])
	case dictionary([String: SettingsOpaqueValue])

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Int.self) {
			self = .integer(value)
		} else if let value = try? container.decode(Double.self) {
			self = .double(value)
		} else if let value = try? container.decode(Date.self) {
			self = .date(value)
		} else if let value = try? container.decode(Data.self) {
			self = .data(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([SettingsOpaqueValue].self) {
			self = .array(value)
		} else if let value = try? container.decode(
			[String: SettingsOpaqueValue].self
		) {
			self = .dictionary(value)
		} else {
			throw DecodingError.typeMismatch(
				SettingsOpaqueValue.self,
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "Unsupported property-list settings value"
				)
			)
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case let .string(value):
			try container.encode(value)
		case let .integer(value):
			try container.encode(value)
		case let .double(value):
			try container.encode(value)
		case let .bool(value):
			try container.encode(value)
		case let .data(value):
			try container.encode(value)
		case let .date(value):
			try container.encode(value)
		case let .array(value):
			try container.encode(value)
		case let .dictionary(value):
			try container.encode(value)
		}
	}
}

struct SettingsCodingKey: CodingKey, Hashable {
	let stringValue: String
	let intValue: Int?

	init(_ stringValue: String) {
		self.stringValue = stringValue
		self.intValue = nil
	}

	init?(stringValue: String) {
		self.init(stringValue)
	}

	init?(intValue: Int) {
		self.stringValue = String(intValue)
		self.intValue = intValue
	}
}
