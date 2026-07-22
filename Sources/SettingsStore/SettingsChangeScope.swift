import Foundation

public enum FieldReloadKind {
    case live
    case newSurface
}

public enum SettingsChangeScope: Equatable {
    case globalLive
    case globalNewSurface
    case hostOverride(HostId)

    public static let liveReloadable: [PartialFieldKey: FieldReloadKind] = [
        .fontFamily: .live,
        .fontSize: .live,
        .lineHeight: .live,
        .cursorStyle: .live,
        .cursorBlink: .live,
        .bell: .live,
        .windowOpacity: .newSurface,
        .windowPaddingX: .live,
        .windowPaddingY: .live,
        .theme: .live,
        .scrollbackBytes: .newSurface,
        .titlebarStyle: .newSurface,
		.prefersNativeMobileKeyboard: .newSurface,
		.opaque: .newSurface,
    ]

    public static func diff(old: CatermSettings, new: CatermSettings) -> SettingsChangeScope? {
		if old.unknownFields != new.unknownFields {
			return .globalNewSurface
		}
        let changedGlobal = changedKeys(old: old.global, new: new.global)
        if !changedGlobal.isEmpty {
            let anyLive = changedGlobal.contains { (liveReloadable[$0] ?? .newSurface) == .live }
            return anyLive ? .globalLive : .globalNewSurface
        }
        let allHostIds = Set(old.hostOverrides.keys).union(new.hostOverrides.keys)
        for id in allHostIds where old.hostOverrides[id] != new.hostOverrides[id] {
            return .hostOverride(id)
        }
        return nil
    }

    private static func changedKeys(old: PartialSettings, new: PartialSettings) -> Set<PartialFieldKey> {
        var s: Set<PartialFieldKey> = []
        if old.fontFamily != new.fontFamily { s.insert(.fontFamily) }
        if old.fontSize != new.fontSize { s.insert(.fontSize) }
        if old.lineHeight != new.lineHeight { s.insert(.lineHeight) }
        if old.cursorStyle != new.cursorStyle { s.insert(.cursorStyle) }
        if old.cursorBlink != new.cursorBlink { s.insert(.cursorBlink) }
        if old.bell != new.bell { s.insert(.bell) }
        if old.scrollbackBytes != new.scrollbackBytes { s.insert(.scrollbackBytes) }
        if old.windowOpacity != new.windowOpacity { s.insert(.windowOpacity) }
        if old.windowPaddingX != new.windowPaddingX { s.insert(.windowPaddingX) }
        if old.windowPaddingY != new.windowPaddingY { s.insert(.windowPaddingY) }
        if old.titlebarStyle != new.titlebarStyle { s.insert(.titlebarStyle) }
        if old.theme != new.theme { s.insert(.theme) }
		if old.prefersNativeMobileKeyboard != new.prefersNativeMobileKeyboard {
			s.insert(.prefersNativeMobileKeyboard)
		}
		if old.unknownFields != new.unknownFields { s.insert(.opaque) }
        return s
    }
}

public enum PartialFieldKey: Hashable {
    case fontFamily, fontSize, lineHeight
    case cursorStyle, cursorBlink
    case bell
    case scrollbackBytes
    case windowOpacity, windowPaddingX, windowPaddingY
    case titlebarStyle
    case theme
	case prefersNativeMobileKeyboard
	case opaque
}
