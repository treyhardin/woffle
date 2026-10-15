import Foundation

/// Collections: user-made groups of families, persisted to `collections.json` next to
/// the overrides file.
extension FontService {
    var activeCollection: FontCollection? {
        guard let activeCollectionID else { return nil }
        return collections.first { $0.id == activeCollectionID }
    }

    /// Library fonts belonging to the collection.
    func fonts(in collection: FontCollection) -> [FontItem] {
        let families = Set(collection.families)
        return fonts.filter { families.contains($0.familyName) }
    }

    func collections(containing font: FontItem) -> [FontCollection] {
        collections.filter { $0.families.contains(font.familyName) }
    }

    /// Families in the collection that are currently in the library (for sidebar counts).
    func count(in collection: FontCollection) -> Int {
        let present = Set(fonts.map(\.familyName))
        return Set(collection.families).intersection(present).count
    }

    @discardableResult
    func createCollection(named name: String, families: [String] = []) -> FontCollection {
        var unique: [String] = []
        for family in families where !unique.contains(family) { unique.append(family) }
        let collection = FontCollection(name: Self.cleanName(name), families: unique)
        collections.append(collection)
        saveCollections()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = Self.cleanName(name)
        saveCollections()
    }

    /// Deletes the collection only — its fonts stay in the library.
    func deleteCollection(_ id: UUID) {
        if activeCollectionID == id { activeCollectionID = nil }
        collections.removeAll { $0.id == id }
        saveCollections()
    }

    func addFamilies(_ families: [String], to id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        for family in families where !collections[index].families.contains(family) {
            collections[index].families.append(family)
        }
        saveCollections()
        let name = collections[index].name
        toast.flash(families.count == 1 ? "Added “\(families[0])” to \(name)" : "Added \(families.count) fonts to \(name)")
    }

    func removeFamilies(_ families: [String], from id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].families.removeAll { families.contains($0) }
        saveCollections()
    }

    /// Menu toggle: adds the fonts, or removes them if they're all already in it.
    func toggle(_ fonts: [FontItem], in collection: FontCollection) {
        let families = fonts.map(\.familyName)
        if families.allSatisfy(collection.families.contains) {
            removeFamilies(families, from: collection.id)
        } else {
            addFamilies(families, to: collection.id)
        }
    }

    // MARK: - Persistence

    private var collectionsURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("collections.json")
    }

    func loadCollections() {
        guard let data = try? Data(contentsOf: collectionsURL),
              let decoded = try? JSONDecoder().decode([FontCollection].self, from: data) else { return }
        collections = decoded
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: collectionsURL, options: .atomic)
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Collection" : trimmed
    }
}
