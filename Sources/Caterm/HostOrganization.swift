import Foundation
import SSHCommandBuilder

enum HostOrganizationText {
	static func makeOrganization(group: String, tags: String) -> HostOrganization {
		HostOrganization(
			groupPath: group.split(separator: "/").map(String.init),
			tags: tags.split(whereSeparator: { $0 == "," || $0.isNewline })
				.map(String.init)
		)
	}

	static func groupText(_ organization: HostOrganization) -> String {
		organization.groupPath.joined(separator: " / ")
	}

	static func tagsText(_ organization: HostOrganization) -> String {
		organization.tags.joined(separator: ", ")
	}
}

enum HostOrganizationQuery {
	static func filter(
		_ hosts: [SSHHost],
		query: String,
		groupPath: [String]?,
		tag: String?
	) -> [SSHHost] {
		HostSearch.filter(hosts, query: query).filter { host in
			let matchesGroup = groupPath.map { selectedPath in
				selectedPath.isEmpty
					? host.organization.groupPath.isEmpty
					: host.organization.groupPath.starts(with: selectedPath)
			} ?? true
			let matchesTag = tag.map { selectedTag in
				host.organization.tags.contains {
					$0.localizedCaseInsensitiveCompare(selectedTag) == .orderedSame
				}
			} ?? true
			return matchesGroup && matchesTag
		}
	}

	static func groups(in hosts: [SSHHost]) -> [[String]] {
		let paths = hosts.flatMap { host in
			host.organization.groupPath.indices.map { index in
				Array(host.organization.groupPath.prefix(index + 1))
			}
		}
		return Array(Set(paths))
			.sorted { lhs, rhs in
				lhs.joined(separator: "/").localizedStandardCompare(
					rhs.joined(separator: "/")
				) == .orderedAscending
			}
	}

	static func tags(in hosts: [SSHHost]) -> [String] {
		var representativeByKey: [String: String] = [:]
		for tag in hosts.flatMap(\.organization.tags) {
			let key = tag.folding(
				options: [.caseInsensitive, .diacriticInsensitive],
				locale: nil
			)
			representativeByKey[key] = representativeByKey[key] ?? tag
		}
		return representativeByKey.values.sorted {
			$0.localizedStandardCompare($1) == .orderedAscending
		}
	}
}

enum HostOrganizationMutation {
	case setGroup([String])
	case addTags([String])
	case removeTags([String])

	static func apply(
		_ mutation: HostOrganizationMutation,
		to organization: HostOrganization
	) -> HostOrganization {
		switch mutation {
		case .setGroup(let groupPath):
			return HostOrganization(
				groupPath: groupPath, tags: organization.tags
			)
		case .addTags(let tags):
			return HostOrganization(
				groupPath: organization.groupPath,
				tags: organization.tags + tags
			)
		case .removeTags(let tags):
			let keys = Set(tags.map {
				$0.folding(
					options: [.caseInsensitive, .diacriticInsensitive],
					locale: nil
				)
			})
			return HostOrganization(
				groupPath: organization.groupPath,
				tags: organization.tags.filter {
					!keys.contains($0.folding(
						options: [.caseInsensitive, .diacriticInsensitive],
						locale: nil
					))
				}
			)
		}
	}
}
