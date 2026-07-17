import Foundation

/// Owns the timing and ownership policy that decides when an SSH session is
/// usable. The terminal surface adapter supplies snapshots and translates the
/// emitted events into SessionStore transitions.
@MainActor
final class SessionLivenessProbe {
	struct Generation: Equatable {
		let rawValue: Int

		init(_ rawValue: Int) {
			self.rawValue = rawValue
		}
	}

	enum Observation: Equatable {
		case sessionMissing
		case surfaceUnavailable(generation: Generation)
		case surfaceRunning(generation: Generation)
		case surfaceExited(generation: Generation)
	}

	enum Event: Equatable {
		case provisional
		case confirmed
		case lost
	}

	struct Timing: Equatable {
		let surfacePollInterval: Duration
		let surfaceDiscoveryTimeout: Duration
		let provisionalDelay: Duration
		let confirmationDelay: Duration

		static let standard = Timing(
			validatedSurfacePollInterval: .milliseconds(50),
			surfaceDiscoveryTimeout: .seconds(3),
			provisionalDelay: .milliseconds(600),
			confirmationDelay: .milliseconds(2_400)
		)

		init?(
			surfacePollInterval: Duration,
			surfaceDiscoveryTimeout: Duration,
			provisionalDelay: Duration,
			confirmationDelay: Duration
		) {
			guard surfacePollInterval > .zero,
			      surfaceDiscoveryTimeout >= .zero,
			      provisionalDelay >= .zero,
			      confirmationDelay >= .zero else { return nil }
			self.init(
				validatedSurfacePollInterval: surfacePollInterval,
				surfaceDiscoveryTimeout: surfaceDiscoveryTimeout,
				provisionalDelay: provisionalDelay,
				confirmationDelay: confirmationDelay
			)
		}

		private init(
			validatedSurfacePollInterval: Duration,
			surfaceDiscoveryTimeout: Duration,
			provisionalDelay: Duration,
			confirmationDelay: Duration
		) {
			self.surfacePollInterval = validatedSurfacePollInterval
			self.surfaceDiscoveryTimeout = surfaceDiscoveryTimeout
			self.provisionalDelay = provisionalDelay
			self.confirmationDelay = confirmationDelay
		}
	}

	typealias ObservationProvider = @MainActor () -> Observation
	typealias SurfacePreparer = @MainActor () -> Void
	typealias Sleeper = @MainActor (Duration) async -> Void
	typealias EventHandler = @MainActor (Event) -> Void

	private enum State {
		case idle
		case observing
		case provisional
		case finished
	}

	private let expectedGeneration: Generation
	private let timing: Timing
	private let observation: ObservationProvider
	private let prepareSurface: SurfacePreparer
	private let sleep: Sleeper
	private let onEvent: EventHandler
	private var state = State.idle

	init(
		expectedGeneration: Generation,
		timing: Timing = .standard,
		observation: @escaping ObservationProvider,
		prepareSurface: @escaping SurfacePreparer,
		sleep: @escaping Sleeper = { duration in
			try? await Task.sleep(for: duration)
		},
		onEvent: @escaping EventHandler
	) {
		self.expectedGeneration = expectedGeneration
		self.timing = timing
		self.observation = observation
		self.prepareSurface = prepareSurface
		self.sleep = sleep
		self.onEvent = onEvent
	}

	func run() async {
		guard case .idle = state else { return }
		guard await waitForUsableSurface() else {
			guard !Task.isCancelled else { return }
			finish(with: .lost)
			return
		}

		state = .observing
		prepareSurface()
		guard !isFinished else { return }

		await sleep(timing.provisionalDelay)
		guard !isFinished else { return }
		guard !Task.isCancelled else { return }
		guard connectionSnapshotIsUsable() else {
			finish(with: .lost)
			return
		}
		state = .provisional
		onEvent(.provisional)

		await sleep(timing.confirmationDelay)
		guard !isFinished else { return }
		guard !Task.isCancelled else { return }
		guard connectionSnapshotIsUsable() else {
			finish(with: .lost)
			return
		}
		finish(with: .confirmed)
	}

	func sessionDidBecomeLive() {
		guard acceptsSurfaceSignals else { return }
		guard connectionSnapshotIsUsable() else {
			finish(with: .lost)
			return
		}
		finish(with: .confirmed)
	}

	func connectionDidEnd() {
		guard acceptsSurfaceSignals else { return }
		finish(with: .lost)
	}

	private func waitForUsableSurface() async -> Bool {
		var elapsed = Duration.zero
		while true {
			switch observation() {
			case .sessionMissing:
				return false
			case .surfaceUnavailable(let generation):
				guard generation == expectedGeneration,
				      elapsed < timing.surfaceDiscoveryTimeout else { return false }
			case .surfaceRunning(let generation):
				return generation == expectedGeneration
			case .surfaceExited:
				return false
			}
			await sleep(timing.surfacePollInterval)
			guard !Task.isCancelled else { return false }
			elapsed += timing.surfacePollInterval
		}
	}

	private func connectionSnapshotIsUsable() -> Bool {
		guard case .surfaceRunning(let generation) = observation() else { return false }
		return generation == expectedGeneration
	}

	private var acceptsSurfaceSignals: Bool {
		switch state {
		case .observing, .provisional:
			return true
		case .idle, .finished:
			return false
		}
	}

	private var isFinished: Bool {
		if case .finished = state { return true }
		return false
	}

	private func finish(with event: Event) {
		guard !isFinished else { return }
		state = .finished
		onEvent(event)
	}
}
