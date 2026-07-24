import SwiftUI

enum WorkspaceMotionPolicy {
	static func presentationAnimation(reduceMotion: Bool) -> Animation? {
		reduceMotion ? nil : .easeInOut(duration: 0.22)
	}

	static func statusAnimation(reduceMotion: Bool) -> Animation? {
		reduceMotion ? nil : .easeOut(duration: 0.15)
	}

	static func tipAnimation(reduceMotion: Bool) -> Animation? {
		reduceMotion ? nil : .easeInOut(duration: 0.3)
	}
}
