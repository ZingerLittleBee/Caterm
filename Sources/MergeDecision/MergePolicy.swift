public enum MergeDecision: Equatable, Sendable {
	case local
	case incoming
	case equivalent
}

/// Composes an entity's last-write-wins rules in precedence order. Callers
/// retain their own operation vocabulary; this type owns only the decision.
public struct MergePolicy<Local, Incoming> {
	private typealias Rule = (Local, Incoming) -> MergeDecision

	private var rules: [Rule]
	private var tieBreaker: Rule

	public init<Value: Comparable>(
		local: @escaping (Local) -> Value,
		incoming: @escaping (Incoming) -> Value
	) {
		rules = [Self.rule(local: local, incoming: incoming)]
		tieBreaker = { _, _ in .equivalent }
	}

	public func then<Value: Comparable>(
		local: @escaping (Local) -> Value,
		incoming: @escaping (Incoming) -> Value
	) -> Self {
		var copy = self
		copy.rules.append(Self.rule(local: local, incoming: incoming))
		return copy
	}

	/// Adds a rule where a present value is newer than a missing value.
	public func thenOptional<Value: Comparable>(
		local: @escaping (Local) -> Value?,
		incoming: @escaping (Incoming) -> Value?
	) -> Self {
		var copy = self
		copy.rules.append { localEntity, incomingEntity in
			let localValue = local(localEntity)
			let incomingValue = incoming(incomingEntity)
			switch (localValue, incomingValue) {
			case let (.some(localValue), .some(incomingValue)):
				return Self.compare(local: localValue, incoming: incomingValue)
			case (.none, .some):
				return .incoming
			case (.some, .none):
				return .local
			case (.none, .none):
				return .equivalent
			}
		}
		return copy
	}

	public func resolvingTies(
		with tieBreaker: @escaping (Local, Incoming) -> MergeDecision
	) -> Self {
		var copy = self
		copy.tieBreaker = tieBreaker
		return copy
	}

	public func decide(
		local: Local,
		incoming: Incoming
	) -> MergeDecision {
		for rule in rules {
			let decision = rule(local, incoming)
			guard decision == .equivalent else { return decision }
		}
		return tieBreaker(local, incoming)
	}

	private static func rule<Value: Comparable>(
		local: @escaping (Local) -> Value,
		incoming: @escaping (Incoming) -> Value
	) -> Rule {
		{ localEntity, incomingEntity in
			compare(
				local: local(localEntity),
				incoming: incoming(incomingEntity)
			)
		}
	}

	private static func compare<Value: Comparable>(
		local: Value,
		incoming: Value
	) -> MergeDecision {
		if incoming > local { return .incoming }
		if incoming < local { return .local }
		return .equivalent
	}
}
