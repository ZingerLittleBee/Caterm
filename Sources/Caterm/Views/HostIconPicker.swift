import AppKit
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

	/// SF Symbols are versioned — a name added in a later SF Symbols release
	/// renders blank on older macOS. Filter the catalog to symbols this OS
	/// can actually draw so the grid never shows empty cells. Result is
	/// cached (the system symbol set doesn't change at runtime).
	private static var resolved: [Group]?

	static func isAvailable(_ name: String) -> Bool {
		NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
	}

	/// Catalog with unavailable symbols (and now-empty groups) removed.
	static var displayGroups: [Group] {
		if let resolved { return resolved }
		let filtered = groups.compactMap { g -> Group? in
			let syms = g.symbols.filter { isAvailable($0) }
			return syms.isEmpty ? nil : Group(title: g.title, symbols: syms)
		}
		resolved = filtered
		return filtered
	}

	static let groups: [Group] = [
		Group(title: "Servers & Storage", symbols: [
			"server.rack", "xserve", "externaldrive.connected.to.line.below",
			"internaldrive", "internaldrive.fill", "externaldrive",
			"externaldrive.fill", "opticaldiscdrive", "cylinder.split.1x2",
			"cylinder", "cpu", "memorychip", "sdcard", "archivebox",
			"tray.full", "rack",
		]),
		Group(title: "Network", symbols: [
			"network", "globe", "wifi", "antenna.radiowaves.left.and.right",
			"point.3.connected.trianglepath.dotted",
			"point.topleft.down.curvedto.point.bottomright.up",
			"dot.radiowaves.left.and.right", "cable.connector",
			"app.connected.to.app.below.fill", "arrow.triangle.branch",
			"cloud", "cloud.fill", "lock.icloud", "personalhotspot",
		]),
		Group(title: "Devices", symbols: [
			"desktopcomputer", "macpro.gen3", "macpro.gen1", "macmini",
			"laptopcomputer", "pc", "display", "display.2",
			"terminal", "terminal.fill", "keyboard", "tv",
			"shippingbox", "shippingbox.fill", "cube", "cube.fill",
		]),
		Group(title: "Platform & Tools", symbols: [
			"apple.logo", "gearshape", "gearshape.2", "hammer",
			"hammer.fill", "wrench.and.screwdriver", "wrench.adjustable",
			"shield.lefthalf.filled", "lock.shield", "lock.fill",
			"key.fill", "key.horizontal.fill", "checkmark.shield",
			"ladybug", "ant", "ant.fill", "curlybraces",
			"chevron.left.forwardslash.chevron.right", "command",
			"bolt.horizontal.circle", "gauge.with.dots.needle.67percent",
		]),
		Group(title: "Region / Flags", symbols: [
			"globe.americas.fill", "globe.europe.africa.fill",
			"globe.asia.australia.fill", "globe.central.south.asia.fill",
			"flag.fill", "flag.checkered", "flag.2.crossed.fill",
			"mappin.and.ellipse", "map.fill", "location.fill",
			"building.2.fill", "building.columns.fill", "house.fill",
			"globe.badge.chevron.backward",
		]),
		Group(title: "Animals", symbols: [
			"hare", "hare.fill", "tortoise", "tortoise.fill",
			"bird", "bird.fill", "fish", "fish.fill",
			"ladybug.fill", "lizard", "lizard.fill", "pawprint.fill",
		]),
		Group(title: "Accent", symbols: [
			"star.fill", "bolt.fill", "flame.fill", "leaf.fill",
			"sparkles", "circle.hexagongrid.fill", "diamond.fill",
			"heart.fill", "crown.fill", "moon.fill", "sun.max.fill",
			"snowflake", "drop.fill", "atom", "infinity",
			"hexagon.fill", "seal.fill", "shield.fill", "circle.fill",
			"square.fill", "triangle.fill", "rhombus.fill",
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

				ForEach(HostIconCatalog.displayGroups) { group in
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
