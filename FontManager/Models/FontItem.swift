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
    /// Where an installed (not source-folder) font comes from — decides how it's labeled and
    /// whether it can be toggled.
    enum InstallLocation {
        /// Apple's bundled fonts (under /System) — always on.
        case builtIn
        /// Installed in a Fonts folder (~/Library/Fonts, /Library/Fonts) — macOS activates
        /// everything there; remove the file or use Font Book to turn it off.
        case fontsFolder
        /// Activated from somewhere else by an app (e.g. this one, before its source folder
        /// was readable) — can be deactivated like any source-folder font.
        case activatedByApp
    }

    var installLocation: InstallLocation? {
        guard source == .system else { return nil }
        let paths = members.compactMap { $0.fileURL?.standardizedFileURL.path }
        if paths.isEmpty || paths.contains(where: { $0.hasPrefix("/System/") }) { return .builtIn }
        if paths.allSatisfy({ $0.contains("/Library/Fonts/") }) { return .fontsFolder }
        return .activatedByApp
    }

    /// Fonts from source folders, imports, or activated by an app from elsewhere can be
    /// toggled. Built-in and Fonts-folder fonts are managed by macOS.
    var canToggleActivation: Bool {
        installLocation.map { $0 == .activatedByApp } ?? true
    }

    /// Why a font can't be toggled, for labels and messages; nil when it can.
    var activationNote: String? {
        switch installLocation {
        case .builtIn: return "Built into macOS"
        case .fontsFolder: return "In your Fonts folder"
        default: return nil
        }
    }

    var exportableMembers: [FontMember] { members.filter(\.isExportable) }
}

/// A user-made group of fonts. Manual collections list their members as family names (like
/// overrides), so they survive re-scans and folder moves. Smart collections have `rules`
/// instead and include every font that matches them, updating live.
struct FontCollection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var families: [String]
    /// Set for smart collections; nil for manual ones.
    var rules: SmartCollectionRules?

    var isSmart: Bool { rules != nil }

    init(name: String, families: [String] = [], rules: SmartCollectionRules? = nil) {
        self.id = UUID()
        self.name = name
        self.families = families
        self.rules = rules
    }
}

/// What a smart collection matches. Within a category any selected value matches ("Serif or
/// Slab Serif"); categories combine with AND. An empty category means "any".
struct SmartCollectionRules: Codable, Hashable {
    var classifications: Set<FontClassification> = []
    var widths: Set<FontWidth> = []
    /// Display foundry names (as in the Foundry filter, including "Unknown").
    var foundries: Set<String> = []

    var isEmpty: Bool { classifications.isEmpty && widths.isEmpty && foundries.isEmpty }
}

/// Opens the smart collection editor: a new collection (`collection == nil`) or an existing one.
struct SmartCollectionEditorRequest: Identifiable {
    let id = UUID()
    var collection: FontCollection?
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
