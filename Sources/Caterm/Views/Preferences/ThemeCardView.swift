import SwiftUI
import SettingsStore

public struct ThemeCardView: View {
    let theme: ThemeRecord
    let isSelected: Bool
    let action: () -> Void

    public init(theme: ThemeRecord, isSelected: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(theme.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(0..<min(8, theme.palette.count), id: \.self) { i in
                        Color.fromHex(theme.palette[i])
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                Color.fromHex(theme.background)
                    .frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    static func fromHex(_ hex: String) -> Color {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let v = UInt32(cleaned, radix: 16) else { return .black }
        return Color(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}
