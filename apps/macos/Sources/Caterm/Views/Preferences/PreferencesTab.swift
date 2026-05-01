import AppKit
import SwiftUI

public struct PreferencesTab {
    public let title: String
    public let systemImage: String
    public let viewBuilder: () -> AnyView

    public init(title: String, systemImage: String, view: @escaping () -> some View) {
        self.title = title
        self.systemImage = systemImage
        self.viewBuilder = { AnyView(view()) }
    }
}
