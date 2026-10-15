import Foundation
import AppKit
import CoreText

@MainActor
class FontService: ObservableObject {
    @Published var fonts: [FontItem] = []
    @Published var searchText: String = ""
    @Published var customDirectories: [String] = []
    @Published var filterStatus: StatusFilter = .all
    @Published var filterClassification: FontClassification?
    @Published var filterWidth: FontWidth?
    /// Selected foundry to filter by; `nil` means "All". Matches `displayFoundry`.
    @Published var filterFoundry: String?
    /// How the main browse pane (grid/list) is ordered; the sidebar is always A–Z.
    /// Persisted across launches.
    @Published var sortOrder: SortOrder = .nameAscending {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: sortOrderKey) }
    }
    /// Selected font ids (multi-selection), kept here so filtering can keep selected rows visible.
    @Published var selection: Set<String> = []
    /// User-made collections, shown in the sidebar. Persisted in `collections.json`.
    @Published var collections: [FontCollection] = []
    /// The collection being browsed; `nil` means All Fonts. Switching clears the selection
    /// so you land on the collection's grid.
    @Published var activeCollectionID: UUID? {
        didSet { if activeCollectionID != oldValue { selection = [] } }
    }
    /// Attribute changes proposed by AI tools, awaiting review. Persisted.
    @Published var suggestions: [AttributeSuggestion] = []
    /// Set to open the smart collection editor (new, or editing an existing one).
    @Published var smartCollectionEditor: SmartCollectionEditorRequest?
    /// Set to ask the UI for a collection name (new or rename).
    @Published var collectionPrompt: CollectionPrompt?
    /// Incremented to request the search field take focus (Cmd+F).
    @Published var searchFocusToken = 0
    /// User Style/Width overrides, keyed by `FontItem.id`. Persisted on-device.
    @Published private(set) var overrides: [String: FontOverride] = [:]
    /// True while fonts are being (re)enumerated in the background.
    @Published private(set) var isLoading = false
    /// True while a re-scan is in flight (drives the toolbar sync indicator).
    @Published private(set) var isSyncing = false
    /// When the library last finished (re)scanning; nil until the first load completes.
    @Published private(set) var lastSyncedAt: Date?

    /// Watches the custom source folders so dropped-in fonts appear without a relaunch.
    private var directoryWatcher: DirectoryWatcher?

    private let directoriesKey = "customFontDirectories"
    private let importedKey = "importedFontFiles"
    private let sortOrderKey = "fontSortOrder"
    nonisolated private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]

    /// Paths of individually-converted fonts the app activates on launch.
    private var importedPaths: [String] = []

    /// Persistent access to source folders and imported font files (required in the sandbox).
    private let directoryAccess = BookmarkStore(defaultsKey: "customFontDirectoryBookmarks")
    private let importedAccess = BookmarkStore(defaultsKey: "importedFontBookmarks")

    /// System fonts rarely change, so cache them and only rebuild custom/imported on edits.
    private var cachedSystemItems: [FontItem]?

    /// Lightweight, Sendable system-font metadata gathered on the main thread.
    private struct RawMember: Sendable {
        let postScriptName: String
        let styleName: String
        let weight: Int
    }
    private struct RawFamily: Sendable {
        let family: String
        let members: [RawMember]
    }

    enum StatusFilter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case inactive = "Inactive"
        case missingInfo = "Missing Info"
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case nameAscending = "Name (A–Z)"
        case nameDescending = "Name (Z–A)"
        case mostRecent = "Most Recent"

        var id: String { rawValue }

        /// Sort predicate for two families. Ties (and undated fonts under date sorts) fall
        /// back to A–Z so the order is always stable.
        func areInIncreasingOrder(_ a: FontItem, _ b: FontItem) -> Bool {
            func byName(ascending: Bool = true) -> Bool {
                let result = a.familyName.localizedCaseInsensitiveCompare(b.familyName)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            switch self {
            case .nameAscending: return byName()
            case .nameDescending: return byName(ascending: false)
            case .mostRecent:
                switch (a.dateAdded, b.dateAdded) {
                case let (x?, y?):
                    if x == y { return byName() }
                    return x > y
                case (_?, nil): return true   // dated fonts sort ahead of undated ones
                case (nil, _?): return false
                case (nil, nil): return byName()
                }
            }
        }
    }

    // MARK: - Effective values (system value unless the user overrode it)

    /// Overrides are keyed by family name (not FontItem.id): Style/Width are intrinsic to
    /// the typeface, so the override survives directory moves and source changes, and
    /// reapplies if the font is re-added.
    private func overrideKey(_ font: FontItem) -> String { font.familyName }

    func effectiveClassification(_ font: FontItem) -> FontClassification {
        overrides[overrideKey(font)]?.classification ?? font.classification
    }

    func effectiveWidth(_ font: FontItem) -> FontWidth {
        overrides[overrideKey(font)]?.width ?? font.width
    }

    /// Foundry label for filtering/display; fonts with no foundry info bucket under "Unknown".
    static let unknownFoundry = "Unknown"

    /// User's foundry override if set, otherwise the value derived from the font's metadata.
    func effectiveFoundry(_ font: FontItem) -> String? {
        overrides[overrideKey(font)]?.foundry ?? font.foundry
    }

    func displayFoundry(_ font: FontItem) -> String {
        effectiveFoundry(font) ?? Self.unknownFoundry
    }

    func isFoundryOverridden(_ font: FontItem) -> Bool {
        overrides[overrideKey(font)]?.foundry != nil
    }

    /// Every known foundry name (effective values), for the editor's autocomplete list.
    var allFoundries: [String] {
        Set(fonts.compactMap(effectiveFoundry))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func isOverridden(_ font: FontItem) -> Bool {
        !(overrides[overrideKey(font)]?.isEmpty ?? true)
    }

    func isClassificationOverridden(_ font: FontItem) -> Bool {
        overrides[overrideKey(font)]?.classification != nil
    }

    func isWidthOverridden(_ font: FontItem) -> Bool {
        overrides[overrideKey(font)]?.width != nil
    }

    /// A font still missing a Style after system detection and any override.
    func isMissingInfo(_ font: FontItem) -> Bool {
        effectiveClassification(font) == .unclassified
    }

    /// Number of fonts still missing a Style (drives the "Missing Info" count).
    var missingCount: Int {
        fonts.filter(isMissingInfo).count
    }

    /// Total families for a status bucket, independent of other filters (for the dropdown count).
    func count(for status: StatusFilter) -> Int {
        switch status {
        case .all: return fonts.count
        case .active: return fonts.filter { $0.isActive }.count
        case .inactive: return fonts.filter { !$0.isActive }.count
        case .missingInfo: return missingCount
        }
    }

    func selectAllVisible() {
        selection = Set(filteredFonts.map { $0.id })
    }

    func focusSearch() {
        searchFocusToken &+= 1
    }

    /// True when any filter (beyond the default "All" everything) is active.
    var hasActiveFilters: Bool {
        filterStatus != .all
            || filterClassification != nil || filterWidth != nil
            || filterFoundry != nil || !searchText.isEmpty
    }

    func clearFilters() {
        filterStatus = .all
        filterClassification = nil
        filterWidth = nil
        filterFoundry = nil
        searchText = ""
    }

    /// Classifications present in the library (effective values), in enum
    /// order — drives the filter controls so they never offer an empty bucket.
    var availableClassifications: [FontClassification] {
        let present = Set(fonts.map(effectiveClassification))
        // "Unclassified" isn't a meaningful bucket to filter by — omit it from the controls.
        return FontClassification.allCases.filter { $0 != .unclassified && present.contains($0) }
    }

    /// Widths present in the library, in enum order.
    var availableWidths: [FontWidth] {
        let present = Set(fonts.map(effectiveWidth))
        return FontWidth.allCases.filter { present.contains($0) }
    }

    /// Foundries present in the library, by font count (most first), with
    /// "Unknown" always last. Ties break alphabetically for a stable order.
    var availableFoundries: [String] {
        var counts: [String: Int] = [:]
        for font in fonts { counts[displayFoundry(font), default: 0] += 1 }
        let named = counts.keys.filter { $0 != Self.unknownFoundry }.sorted { a, b in
            counts[a]! != counts[b]! ? counts[a]! > counts[b]!
                : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return counts[Self.unknownFoundry] != nil ? named + [Self.unknownFoundry] : named
    }

    /// Families for a foundry (for the menu badge counts).
    func count(forFoundry name: String) -> Int {
        fonts.filter { displayFoundry($0) == name }.count
    }

    /// Fonts matching the current search and filters, A–Z (the sidebar's order).
    var filteredFonts: [FontItem] {
        var result = fonts

        if let collection = activeCollection {
            result = result.filter { matches($0, collection) }
        }

        // Already-selected rows stay visible even after they stop matching, so editing a
        // font's Style in "Missing Info" mode doesn't make it vanish out from under you.
        switch filterStatus {
        case .all: break
        case .active: result = result.filter { $0.isActive || selection.contains($0.id) }
        case .inactive: result = result.filter { !$0.isActive || selection.contains($0.id) }
        case .missingInfo: result = result.filter { isMissingInfo($0) || selection.contains($0.id) }
        }

        // Style/Width are unresolved in "Missing Info" mode, so those sub-filters don't apply
        // there; elsewhere they're ignored if their value isn't available (prevents a
        // permanently-empty list when the selected bucket disappears).
        let showingMissing = filterStatus == .missingInfo
        if !showingMissing, let classification = filterClassification, availableClassifications.contains(classification) {
            result = result.filter { effectiveClassification($0) == classification || selection.contains($0.id) }
        }

        if !showingMissing, let width = filterWidth, availableWidths.contains(width) {
            result = result.filter { effectiveWidth($0) == width || selection.contains($0.id) }
        }

        if let foundry = filterFoundry, availableFoundries.contains(foundry) {
            result = result.filter { displayFoundry($0) == foundry || selection.contains($0.id) }
        }

        if !searchText.isEmpty {
            result = result.filter { font in
                font.familyName.localizedCaseInsensitiveContains(searchText)
                    || effectiveClassification(font).rawValue.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result.sorted(by: SortOrder.nameAscending.areInIncreasingOrder)
    }

    /// `filteredFonts` in the browse pane's chosen order.
    var browseFonts: [FontItem] {
        sortOrder == .nameAscending ? filteredFonts : filteredFonts.sorted(by: sortOrder.areInIncreasingOrder)
    }

    let toast: ToastCenter

    init(toast: ToastCenter) {
        self.toast = toast
        customDirectories = UserDefaults.standard.stringArray(forKey: directoriesKey) ?? []
        importedPaths = UserDefaults.standard.stringArray(forKey: importedKey) ?? []
        directoryAccess.startAccessing(customDirectories)
        importedAccess.startAccessing(importedPaths)
        if let raw = UserDefaults.standard.string(forKey: sortOrderKey), let saved = SortOrder(rawValue: raw) {
            sortOrder = saved
        }
        loadOverrides()
        loadCollections()
        loadSuggestions()
        loadAllFonts()

        // Auto-refresh when files are added/removed in a watched source folder.
        let watcher = DirectoryWatcher { [weak self] in
            Task { @MainActor in self?.reloadUserFonts() }
        }
        watcher.watch(customDirectories)
        directoryWatcher = watcher
    }

    // MARK: - User overrides

    func setClassificationOverride(_ classification: FontClassification, for font: FontItem) {
        applyClassification(classification, to: font)
        saveOverrides()
    }

    func setWidthOverride(_ width: FontWidth, for font: FontItem) {
        applyWidth(width, to: font)
        saveOverrides()
    }

    /// Sets a free-text foundry override. Empty text, or text matching the metadata-derived
    /// foundry, clears the override instead (so it reverts to the detected value).
    func setFoundryOverride(_ raw: String, for font: FontItem) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = overrideKey(font)
        var override = overrides[key] ?? FontOverride()
        override.foundry = (trimmed.isEmpty || trimmed == font.foundry) ? nil : trimmed
        overrides[key] = override.isEmpty ? nil : override
        saveOverrides()
    }

    func resetFoundryOverride(for font: FontItem) {
        guard var override = overrides[overrideKey(font)] else { return }
        override.foundry = nil
        overrides[overrideKey(font)] = override.isEmpty ? nil : override
        saveOverrides()
    }

    func resetOverride(for font: FontItem) {
        overrides[overrideKey(font)] = nil
        saveOverrides()
    }

    func resetClassificationOverride(for font: FontItem) {
        guard var override = overrides[overrideKey(font)] else { return }
        override.classification = nil
        overrides[overrideKey(font)] = override.isEmpty ? nil : override
        saveOverrides()
    }

    func resetWidthOverride(for font: FontItem) {
        guard var override = overrides[overrideKey(font)] else { return }
        override.width = nil
        overrides[overrideKey(font)] = override.isEmpty ? nil : override
        saveOverrides()
    }

    // Bulk variants for multi-selection (one save for the whole batch).

    func setClassificationOverride(_ classification: FontClassification, for fonts: [FontItem]) {
        for font in fonts { applyClassification(classification, to: font) }
        saveOverrides()
    }

    func setWidthOverride(_ width: FontWidth, for fonts: [FontItem]) {
        for font in fonts { applyWidth(width, to: font) }
        saveOverrides()
    }

    func resetOverride(for fonts: [FontItem]) {
        for font in fonts { overrides[overrideKey(font)] = nil }
        saveOverrides()
    }

    func setActive(_ active: Bool, for items: [FontItem]) {
        let items = items.filter(\.canToggleActivation)
        guard !items.isEmpty else {
            toast.flash("These fonts are built into macOS or in your Fonts folder, so macOS keeps them on.", isError: true)
            return
        }
        var ok = 0
        var failed = 0
        for font in items {
            let success = active ? activateFont(font, notify: false) : deactivateFont(font, notify: false)
            if success { ok += 1 } else { failed += 1 }
        }
        let verb = active ? "Activated" : "Deactivated"
        if failed == 0 {
            toast.flash("\(verb) \(ok) font\(ok == 1 ? "" : "s")")
        } else {
            toast.flash("\(verb) \(ok), \(failed) failed", isError: true)
        }
    }

    /// Choosing the system value clears the override for that field.
    private func applyClassification(_ classification: FontClassification, to font: FontItem) {
        let key = overrideKey(font)
        var override = overrides[key] ?? FontOverride()
        override.classification = classification == font.classification ? nil : classification
        overrides[key] = override.isEmpty ? nil : override
    }

    private func applyWidth(_ width: FontWidth, to font: FontItem) {
        let key = overrideKey(font)
        var override = overrides[key] ?? FontOverride()
        override.width = width == font.width ? nil : width
        overrides[key] = override.isEmpty ? nil : override
    }

    private var overridesURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("overrides.json")
    }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesURL),
              let decoded = try? JSONDecoder().decode([String: FontOverride].self, from: data) else { return }

        // Migrate old id-based keys ("system:Family", "custom:/dir:Family") to family names.
        var migrated: [String: FontOverride] = [:]
        var didMigrate = false
        for (key, value) in decoded {
            let family: String
            if key.contains(":") {
                family = String(key.split(separator: ":").last ?? Substring(key))
                didMigrate = true
            } else {
                family = key
            }
            if var existing = migrated[family] {
                existing.classification = existing.classification ?? value.classification
                existing.width = existing.width ?? value.width
                existing.foundry = existing.foundry ?? value.foundry
                migrated[family] = existing
            } else {
                migrated[family] = value
            }
        }
        overrides = migrated
        if didMigrate { saveOverrides() }
    }

    private func saveOverrides() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: overridesURL)
    }

    // MARK: - Font loading

    /// Full (re)load including system fonts. The heavy CoreText work runs off the main actor.
    func loadAllFonts() {
        let raw = systemRaw()           // cheap NSFontManager pass on the main thread
        cachedSystemItems = nil
        rebuild(systemRaw: raw)
    }

    /// Reload only custom + imported fonts, reusing the cached system fonts.
    func reloadUserFonts() {
        guard cachedSystemItems != nil else { loadAllFonts(); return }
        rebuild(systemRaw: nil)
    }

    private func rebuild(systemRaw raw: [RawFamily]?) {
        let dirs = customDirectories
        let imported = importedPaths
        let cachedSystem = cachedSystemItems
        if cachedSystem == nil && fonts.isEmpty { isLoading = true }
        isSyncing = true

        Task.detached(priority: .userInitiated) {
            let system = cachedSystem ?? FontService.buildSystemItems(raw ?? [])
            let custom = FontService.buildCustomItems(dirs)
            let importedResult = FontService.buildImportedItems(imported)
            // Fonts this app activated also show up in macOS's own font list; drop those
            // system entries so each family appears once, under the source that owns it.
            let ownedFiles = Set((custom + importedResult.items).flatMap { $0.members.compactMap { $0.fileURL?.standardizedFileURL.path } })
            let systemOnly = system.filter { item in
                !item.members.allSatisfy { $0.fileURL.map { ownedFiles.contains($0.standardizedFileURL.path) } ?? false }
            }
            let all = (systemOnly + custom + importedResult.items)
                .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedSystemItems = system
                if importedResult.livePaths.count != imported.count {
                    for path in Set(imported).subtracting(importedResult.livePaths) { self.importedAccess.remove(path) }
                    self.importedPaths = importedResult.livePaths
                    UserDefaults.standard.set(importedResult.livePaths, forKey: self.importedKey)
                }
                // Preserve activation that was toggled this session across reloads.
                let previous = Dictionary(self.fonts.map { ($0.id, $0.isActive) }, uniquingKeysWith: { first, _ in first })
                self.fonts = all.map { item in
                    guard let wasActive = previous[item.id] else { return item }
                    var copy = item
                    copy.isActive = wasActive
                    return copy
                }
                self.selection.formIntersection(Set(all.map { $0.id }))
                self.isLoading = false
                self.isSyncing = false
                self.lastSyncedAt = Date()
            }
        }
    }

    /// Cheap system-font metadata via NSFontManager (main thread).
    private func systemRaw() -> [RawFamily] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.map { family in
            let members = (manager.availableMembers(ofFontFamily: family) ?? []).map { info in
                RawMember(
                    postScriptName: info[0] as? String ?? "",
                    styleName: info[1] as? String ?? "Regular",
                    weight: info[2] as? Int ?? 5
                )
            }
            return RawFamily(family: family, members: members)
        }
    }

    /// Newest "date added" across a family's files, matching Finder's Date Added where the
    /// volume records it, otherwise creation date. Drives "Recently Added" sorting.
    nonisolated private static func addedDate(for members: [FontMember]) -> Date? {
        let urls = Set(members.compactMap { $0.fileURL })
        var latest: Date?
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            guard let date = values?.addedToDirectoryDate ?? values?.creationDate else { continue }
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }

    /// A few registered OS/2 vendor IDs, used only as a fallback when a font carries no
    /// human-readable Manufacturer name (chiefly Apple's system fonts → "Apple").
    nonisolated private static let vendorIDNames: [String: String] = [
        "APPL": "Apple", "MONO": "Monotype", "MS": "Microsoft", "LINO": "Linotype",
        "ADBE": "Adobe", "ADBO": "Adobe", "URW": "URW", "URW+": "URW",
        "BITS": "Bitstream", "B&H": "Bigelow & Holmes", "GOOG": "Google",
    ]

    /// Known foundries that publish under several names (sub-brands, legal entities, or a
    /// bare URL). Any normalized name containing `needle` (case-insensitive) collapses to
    /// `canonical`, so all variants group under one entry.
    nonisolated private static let foundryAliases: [(needle: String, canonical: String)] = [
        ("pangram", "Pangram Pangram Foundry"),
        ("monotype", "Monotype"),
        ("adobe", "Adobe"),
        ("displaay", "Displaay Type Foundry"),
        ("blaze", "Blaze Type"),
    ]

    /// Collapse the common legal-entity variants of a foundry name so "Grilli Type",
    /// "Grilli Type AG", and "Grilli Type GmbH" group together, then apply the curated
    /// `foundryAliases` for foundries that use unrelated name variants.
    nonisolated private static func normalizeFoundry(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "®", with: "")
                   .replacingOccurrences(of: "™", with: "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("the ") { s = String(s.dropFirst(4)) }
        for suffix in ["Corporation", "GmbH", "Inc.", "Inc", "LLC", "Ltd.", "Ltd", "AG", "s.r.o."] {
            if s.lowercased().hasSuffix(" " + suffix.lowercased()) {
                s = String(s.dropLast(suffix.count + 1))
                break
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        for alias in foundryAliases where lower.contains(alias.needle) {
            return alias.canonical
        }
        return s
    }

    /// Normalized foundry for a font: Manufacturer name (name ID 8) when present,
    /// otherwise a known OS/2 vendor ID. `nil` when neither yields anything usable.
    nonisolated private static func foundry(for descriptor: CTFontDescriptor) -> String? {
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        if let manufacturer = CTFontCopyName(font, kCTFontManufacturerNameKey) as String?,
           let normalized = normalizeFoundry(manufacturer) {
            return normalized
        }
        if let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           data.count >= 62,
           let tag = String(data: data.subdata(in: 58..<62), encoding: .ascii)?
               .trimmingCharacters(in: CharacterSet(charactersIn: " \0")),
           !tag.isEmpty {
            return vendorIDNames[tag]
        }
        return nil
    }

    nonisolated private static func foundry(forPostScriptName postScriptName: String) -> String? {
        foundry(for: CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 12))
    }

    nonisolated private static func buildSystemItems(_ raw: [RawFamily]) -> [FontItem] {
        raw.map { family in
            let members = family.members.map { rawMember -> FontMember in
                let descriptor = CTFontDescriptorCreateWithNameAndSize(rawMember.postScriptName as CFString, 0)
                let fileURL = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
                return FontMember(
                    postScriptName: rawMember.postScriptName,
                    displayName: "\(family.family) \(rawMember.styleName)",
                    styleName: rawMember.styleName,
                    weight: rawMember.weight,
                    fileURL: fileURL
                )
            }
            let classification = members.first.map {
                FontClassifier.classify(postScriptName: $0.postScriptName, name: family.family)
            } ?? .unclassified
            let width = members.first.map {
                FontClassifier.width(postScriptName: $0.postScriptName, name: family.family)
            } ?? .regular
            let foundry = members.first.flatMap { FontService.foundry(forPostScriptName: $0.postScriptName) }
            return FontItem(familyName: family.family, members: members, source: .system, classification: classification, width: width, dateAdded: addedDate(for: members), foundry: foundry)
        }
    }

    nonisolated private static func buildCustomItems(_ directories: [String]) -> [FontItem] {
        // Fonts this app registered persist across launches (persistent/user scope), so read
        // the live state from CoreText rather than assuming everything starts inactive.
        let registered = Set((CTFontManagerCopyAvailableFontURLs() as? [URL] ?? []).map { $0.standardizedFileURL.path })

        // Keyed by (directory, family) so the same family in two folders stays distinct.
        var groups: [String: (family: String, members: [FontMember], directory: String, descriptor: CTFontDescriptor)] = [:]

        for directory in directories {
            let dirURL = URL(fileURLWithPath: directory)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fontExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor] ?? []

                for descriptor in descriptors {
                    let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? fileURL.deletingPathExtension().lastPathComponent
                    let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? familyName
                    let styleName = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "Regular"

                    let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any]
                    let weightValue = traits?[kCTFontWeightTrait as String] as? Double ?? 0.0
                    let weight = Int((weightValue + 1.0) * 6.5) // Normalize to ~0-13 range

                    let member = FontMember(
                        postScriptName: postScriptName,
                        displayName: "\(familyName) \(styleName)",
                        styleName: styleName,
                        weight: weight,
                        fileURL: fileURL
                    )

                    let groupKey = "\(directory)\u{0}\(familyName)"
                    if var existing = groups[groupKey] {
                        existing.members.append(member)
                        groups[groupKey] = existing
                    } else {
                        groups[groupKey] = (family: familyName, members: [member], directory: directory, descriptor: descriptor)
                    }
                }
            }
        }

        return groups.values.map { value in
            FontItem(
                familyName: value.family,
                members: value.members,
                isActive: value.members.contains { $0.fileURL.map { registered.contains($0.standardizedFileURL.path) } ?? false },
                source: .custom(directory: value.directory),
                classification: FontClassifier.classify(descriptor: value.descriptor, name: value.family),
                width: FontClassifier.width(descriptor: value.descriptor, name: value.family),
                dateAdded: addedDate(for: value.members),
                foundry: foundry(for: value.descriptor)
            )
        }
    }

    /// Builds imported-font items and returns the subset of paths that still exist
    /// (the caller prunes dead paths on the main actor).
    nonisolated private static func buildImportedItems(_ paths: [String]) -> (items: [FontItem], livePaths: [String]) {
        let livePaths = paths.filter { FileManager.default.fileExists(atPath: $0) }

        var membersByFamily: [String: [FontMember]] = [:]
        var descriptorByFamily: [String: CTFontDescriptor] = [:]
        var familyOrder: [String] = []

        for path in livePaths {
            let url = URL(fileURLWithPath: path)

            // Activate so the converted font is usable immediately and across launches.
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .user, &error)

            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? url.deletingPathExtension().lastPathComponent
                let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? familyName
                let styleName = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "Regular"

                let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any]
                let weightValue = traits?[kCTFontWeightTrait as String] as? Double ?? 0.0
                let weight = Int((weightValue + 1.0) * 6.5)

                let member = FontMember(
                    postScriptName: postScriptName,
                    displayName: "\(familyName) \(styleName)",
                    styleName: styleName,
                    weight: weight,
                    fileURL: url
                )

                if membersByFamily[familyName] == nil {
                    familyOrder.append(familyName)
                    descriptorByFamily[familyName] = descriptor
                }
                membersByFamily[familyName, default: []].append(member)
            }
        }

        let items = familyOrder.map { family -> FontItem in
            let classification = descriptorByFamily[family].map {
                FontClassifier.classify(descriptor: $0, name: family)
            } ?? .unclassified
            let width = descriptorByFamily[family].map {
                FontClassifier.width(descriptor: $0, name: family)
            } ?? .regular
            let members = membersByFamily[family] ?? []
            let foundry = descriptorByFamily[family].flatMap { FontService.foundry(for: $0) }
            return FontItem(familyName: family, members: members, isActive: true, source: .imported, classification: classification, width: width, dateAdded: addedDate(for: members), foundry: foundry)
        }
        return (items, livePaths)
    }

    /// Track + activate converted font files so they appear in the library and persist.
    /// Batched so a multi-file conversion triggers a single reload.
    func addImportedFonts(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls where !importedPaths.contains(url.path) {
            importedPaths.append(url.path)
            importedAccess.add(url)
        }
        UserDefaults.standard.set(importedPaths, forKey: importedKey)
        reloadUserFonts()
    }

    /// Deactivate and stop tracking an imported font (leaves the file on disk).
    func removeImportedFont(_ font: FontItem) {
        for member in font.members {
            guard let url = member.fileURL else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(url as CFURL, .user, &error)
            importedPaths.removeAll { $0 == url.path }
            importedAccess.remove(url.path)
        }
        UserDefaults.standard.set(importedPaths, forKey: importedKey)
        reloadUserFonts()
    }

    // MARK: - Directory management

    func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing font files"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        guard !customDirectories.contains(path) else { return }

        customDirectories.append(path)
        directoryAccess.add(url)
        saveDirectories()
        directoryWatcher?.watch(customDirectories)
        reloadUserFonts()
    }

    func removeDirectory(_ path: String) {
        // Deactivate any fonts from this directory first
        for font in fonts {
            if case .custom(let dir) = font.source, dir == path, font.isActive {
                deactivateFont(font)
            }
        }

        customDirectories.removeAll { $0 == path }
        directoryAccess.remove(path)
        saveDirectories()
        directoryWatcher?.watch(customDirectories)
        reloadUserFonts()
    }

    /// Whether the app can currently read a source folder. In the sandbox a folder needs a
    /// user grant — e.g. after moving from the open-source build, or a stale bookmark.
    func canRead(directory path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    /// Asks the user to re-select a folder the app can't read, restoring access.
    func grantAccess(to path: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = "Grant Access"
        panel.message = "Select “\(URL(fileURLWithPath: path).lastPathComponent)” so Font Manager can read its fonts."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        directoryAccess.remove(path)
        if url.path != path, let index = customDirectories.firstIndex(of: path) {
            customDirectories[index] = url.path   // they picked a different (moved) folder
        }
        directoryAccess.add(url)
        saveDirectories()
        directoryWatcher?.watch(customDirectories)
        reloadUserFonts()
    }

    private func saveDirectories() {
        UserDefaults.standard.set(customDirectories, forKey: directoriesKey)
    }

    // MARK: - Font activation

    /// Distinct file URLs for a family (a .ttc/.dfont collection shares one URL across faces).
    private func fileURLs(for font: FontItem) -> [URL] {
        var seen = Set<String>()
        return font.members.compactMap { $0.fileURL }.filter { seen.insert($0.path).inserted }
    }

    @discardableResult
    func deactivateFont(_ font: FontItem, notify: Bool = true) -> Bool {
        guard let index = fonts.firstIndex(where: { $0.id == font.id }) else { return false }
        guard font.canToggleActivation else {
            if notify { toast.flash("“\(font.familyName)” is \(font.activationNote?.lowercased() ?? "managed by macOS") — macOS keeps it on.", isError: true) }
            return false
        }
        let urls = fileURLs(for: font)
        guard !urls.isEmpty else {
            if notify { toast.flash("“\(font.familyName)” can't be deactivated (no font file).", isError: true) }
            return false
        }

        var failed = false
        for url in urls {
            var error: Unmanaged<CFError>?
            // Not-registered means it's already off; that's not a real failure.
            if !CTFontManagerUnregisterFontsForURL(url as CFURL, .user, &error) {
                if let code = error?.takeRetainedValue(), CFErrorGetCode(code) != 201 /* not registered */ {
                    failed = true
                }
            }
        }
        if failed {
            // Some files stayed registered — report the real state rather than flipping the toggle.
            if notify { toast.flash("“\(font.familyName)” couldn't be fully deactivated.", isError: true) }
            return false
        }
        fonts[index].isActive = false
        if notify { toast.flash("Deactivated “\(font.familyName)”") }
        return true
    }

    @discardableResult
    func activateFont(_ font: FontItem, notify: Bool = true) -> Bool {
        guard let index = fonts.firstIndex(where: { $0.id == font.id }) else { return false }
        guard font.canToggleActivation else { return true }   // built-in / Fonts-folder fonts are always on
        let urls = fileURLs(for: font)
        guard !urls.isEmpty else {
            if notify { toast.flash("“\(font.familyName)” can't be activated (no font file).", isError: true) }
            return false
        }

        var failed = false
        for url in urls {
            var error: Unmanaged<CFError>?
            // Already-registered returns false with an error; that's not a real failure.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .user, &error) {
                if let code = error?.takeRetainedValue(), CFErrorGetCode(code) != 105 /* already registered */ {
                    failed = true
                }
            }
        }
        if failed {
            if notify { toast.flash("“\(font.familyName)” couldn't be activated.", isError: true) }
            return false
        }
        fonts[index].isActive = true
        if notify { toast.flash("Activated “\(font.familyName)”") }
        return true
    }

    func toggleFont(_ font: FontItem) {
        if font.isActive {
            deactivateFont(font)
        } else {
            activateFont(font)
        }
    }
}
