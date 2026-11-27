public import Foundation

public struct AAGUIDCatalogEntry: Codable, Sendable, Equatable {
    public var name: String
    public var iconDark: String?
    public var iconLight: String?

    enum CodingKeys: String, CodingKey {
        case name
        case iconDark = "icon_dark"
        case iconLight = "icon_light"
    }
}

public struct AAGUIDCatalog: Sendable {
    private let entries: [String: AAGUIDCatalogEntry]

    public init(entries: [String: AAGUIDCatalogEntry]) {
        self.entries = entries
    }

    public static func bundled() -> AAGUIDCatalog {
        guard let url = Bundle.module.url(forResource: "aaguid", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: AAGUIDCatalogEntry].self, from: data) else {
            return AAGUIDCatalog(entries: [:])
        }
        return AAGUIDCatalog(entries: entries)
    }

    public func providerName(aaguid: UUID?) -> String? {
        guard let aaguid, aaguid.uuidString != "00000000-0000-0000-0000-000000000000" else { return nil }
        return entries[aaguid.uuidString.lowercased()]?.name
    }

    public func icons(aaguid: UUID?) -> (light: String?, dark: String?) {
        guard let aaguid else { return (nil, nil) }
        let entry = entries[aaguid.uuidString.lowercased()]
        return (entry?.iconLight, entry?.iconDark)
    }
}
