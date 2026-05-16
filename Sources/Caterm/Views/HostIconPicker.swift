import SSHCommandBuilder
import SwiftUI

/// Curated set of system SF Symbols offered as host icons. Grouped so the
/// picker can show labelled sections. Every name here is a built-in SF
/// Symbol (no external/bundled assets) so it renders on any supported macOS.
enum HostIconCatalog {
	struct Group: Identifiable {
		let id = UUID()
		let title: String
		let symbols: [String]
	}

	static let groups: [Group] = [
		Group(title: "Servers", symbols: [
			"server.rack", "externaldrive.connected.to.line.below",
			"internaldrive", "externaldrive", "cylinder.split.1x2",
			"network", "point.3.connected.trianglepath.dotted",
			"cloud", "cpu", "memorychip",
		]),
		Group(title: "Devices", symbols: [
			"desktopcomputer", "macpro.gen3", "laptopcomputer",
			"pc", "display", "terminal", "shippingbox", "cube",
		]),
		Group(title: "Platform", symbols: [
			"apple.logo", "gearshape.2", "hammer", "wrench.and.screwdriver",
			"shield.lefthalf.filled", "lock.shield", "key.fill",
			"ladybug", "ant", "hare", "tortoise",
		]),
		Group(title: "Region / Flags", symbols: [
			"globe", "globe.americas.fill", "globe.europe.africa.fill",
			"globe.asia.australia.fill", "flag.fill", "flag.checkered",
			"mappin.and.ellipse", "building.2.fill", "house.fill",
		]),
		Group(title: "Accent", symbols: [
			"star.fill", "bolt.fill", "flame.fill", "leaf.fill",
			"sparkles", "circle.hexagongrid.fill", "diamond.fill",
			"heart.fill",
		]),
	]
}

/// Resolves the SF Symbol to render for a host: the user-chosen `icon`
/// when set, otherwise a credential-derived default. Single source of
/// truth shared by `HostRow` and the form preview.
func hostIconName(for host: SSHHost) -> String {
	if let icon = host.icon, !icon.isEmpty { return icon }
	return defaultHostIconName(for: host.credential)
}

func defaultHostIconName(for credential: CredentialSource) -> String {
	switch credential {
	case .password: return "key.fill"
	case .keyFile:  return "lock.shield.fill"
	case .agent:    return "key.icloud.fill"
	}
}

/// "Icon" form control: a labelled button that previews the current symbol
/// and opens a grouped grid popover. Choosing "Default" clears the override
/// (binding set to `nil`) so the row falls back to the credential icon.
struct HostIconPicker: View {
	@Binding var icon: String?
	/// The credential-derived fallback, previewed when no override is set.
	let fallbackSymbol: String
	@State private var showingPopover = false

	var body: some View {
		Button {
			showingPopover = true
		} label: {
			HStack(spacing: 8) {
				Image(systemName: icon ?? fallbackSymbol)
					.frame(width: 20)
				Text(icon == nil ? "Default" : icon!)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Image(systemName: "chevron.up.chevron.down")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.bordered)
		.help("Choose an icon for this host. Defaults to an icon based on the authentication method.")
		.popover(isPresented: $showingPopover, arrowEdge: .bottom) {
			picker
		}
	}

	private var picker: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				Button {
					icon = nil
					showingPopover = false
				} label: {
					HStack(spacing: 8) {
						Image(systemName: fallbackSymbol).frame(width: 20)
						Text("Default (from auth method)")
						Spacer()
						if icon == nil {
							Image(systemName: "checkmark").foregroundStyle(.tint)
						}
					}
				}
				.buttonStyle(.plain)

				ForEach(HostIconCatalog.groups) { group in
					VStack(alignment: .leading, spacing: 6) {
						Text(group.title)
							.font(.caption.weight(.semibold))
							.foregroundStyle(.secondary)
						LazyVGrid(
							columns: Array(
								repeating: GridItem(.fixed(34), spacing: 6),
								count: 7
							),
							spacing: 6
						) {
							ForEach(group.symbols, id: \.self) { symbol in
								Button {
									icon = symbol
									showingPopover = false
								} label: {
									Image(systemName: symbol)
										.font(.system(size: 15))
										.frame(width: 32, height: 28)
										.background(
											RoundedRectangle(cornerRadius: 6)
												.fill(icon == symbol
												      ? Color.accentColor.opacity(0.25)
												      : Color.secondary.opacity(0.08))
										)
								}
								.buttonStyle(.plain)
								.help(symbol)
							}
						}
					}
				}
			}
			.padding(16)
		}
		.frame(width: 320, height: 360)
	}
}
