import Foundation
import AppKit

enum FontSource: Hashable, Sendable {
    case system
    case custom(directory: String)
    case imported
}

enum FontClassification: String, CaseIterable, Identifiable, Hashable, Codable {
    case serif = "Serif"
    case sansSerif = "Sans Serif"
    case slabSerif = "Slab Serif"
    case script = "Script"
    case blackletter = "Blackletter"
    case monospaced = "Monospaced"
    case symbol = "Symbol"
    case unclassified = "Unclassified"

    var id: String { rawValue }

    // Tolerant decode: any unrecognized value (e.g. a "Display" override persisted before
    // that category was removed) maps to `.unclassified` rather than failing the decode.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FontClassification(rawValue: raw) ?? .unclassified
    }
}

enum FontWidth: String, CaseIterable, Identifiable, Hashable, Codable {
    case condensed = "Condensed"
    case regular = "Regular"
    case expanded = "Expanded"

    var id: String { rawValue }
}

/// User-defined overrides for a font's Style/Width, stored only in this app.
/// A `nil` field means "use the system-derived value."
struct FontOverride: Codable, Equatable {
    var classification: FontClassification?
    var width: FontWidth?
    var foundry: String?

    var isEmpty: Bool { classification == nil && width == nil && foundry == nil }
}

struct FontItem: Identifiable, Hashable, Sendable {
    let id: String
    let familyName: String
    let members: [FontMember]
    var isActive: Bool
    let source: FontSource
    let classification: FontClassification
    let width: FontWidth
    /// When the font's file(s) were added to disk (newest across the family), for "Recently
    /// Added" sorting. `nil` when no backing file exposes a date.
    let dateAdded: Date?
    /// Type foundry / manufacturer, normalized. `nil` when the font exposes no usable
    /// foundry info (shown as "Unknown" in the filter).
    let foundry: String?

    init(familyName: String, members: [FontMember], isActive: Bool = true, source: FontSource = .system, classification: FontClassification = .unclassified, width: FontWidth = .regular, dateAdded: Date? = nil, foundry: String? = nil) {
        self.id = Self.makeID(familyName: familyName, source: source)
        self.familyName = familyName
        self.members = members
        self.isActive = isActive
        self.source = source
        self.classification = classification
        self.width = width
        self.dateAdded = dateAdded
        self.foundry = foundry
    }

    /// IDs are namespaced by source so an imported font can share a family name with
    /// a system font without colliding in lists and selection.
    static func makeID(familyName: String, source: FontSource) -> String {
        switch source {
        case .system: return "system:\(familyName)"
        case .custom(let dir): return "custom:\(dir):\(familyName)"
        case .imported: return "imported:\(familyName)"
        }
    }
}

struct FontMember: Identifiable, Hashable, Sendable {
    let id: String
    let postScriptName: String
    let displayName: String
    let styleName: String
    let weight: Int
    let fileURL: URL?

    init(postScriptName: String, displayName: String, styleName: String, weight: Int, fileURL: URL?) {
        self.id = postScriptName
        self.postScriptName = postScriptName
        self.displayName = displayName
        self.styleName = styleName
        self.weight = weight
        self.fileURL = fileURL
    }
}

extension FontMember {
    /// Apple's bundled fonts live under /System (including downloadable system fonts). Their
    /// license covers use on this Mac only, so the app never exports or converts them.
    static func isAppleSupplied(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/System/")
    }

    /// Whether this face may be exported/converted: it has a backing file that isn't
    /// Apple-supplied. (File-less faces are system-provided too.)
    var isExportable: Bool {
        guard let fileURL else { return false }
        return !Self.isAppleSupplied(fileURL)
    }
}

extension FontItem {
    /// Only fonts this app registers — from source folders or imports — can be activated
    /// and deactivated. Fonts in the macOS font folders are managed by macOS (Font Book).
    var canToggleActivation: Bool { source != .system }

    var exportableMembers: [FontMember] { members.filter(\.isExportable) }
}

/// A user-made group of fonts. Members are family names (like overrides), so a collection
/// survives re-scans and folder moves, and a family appears once however many sources
/// provide it.
struct FontCollection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var families: [String]

    init(name: String, families: [String] = []) {
        self.id = UUID()
        self.name = name
        self.families = families
    }
}

/// A pending request for a collection name, answered by the name alert in ContentView.
enum CollectionPrompt: Identifiable {
    /// New collection, optionally seeded with these families.
    case create(families: [String])
    case rename(FontCollection)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let collection): return "rename-\(collection.id)"
        }
    }
}
