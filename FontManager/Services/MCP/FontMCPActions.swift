import Foundation
import MCP

/// MCP tools that change app state — collections, activation, library refresh — plus the
/// suggestion queue. All go through the same `FontService` methods the UI uses, so changes
/// persist and appear in the app immediately. Main actor because they mutate `FontService`.
/// The caller gates collections/activation behind "Allow changes"; suggestions and refresh
/// are always allowed (suggestions change nothing until the user accepts them).
@MainActor
enum FontMCPActions {

    // MARK: - Collections

    static func createCollection(_ args: [String: Value], service: FontService) -> CallTool.Result {
        guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return FontMCPTools.errorResult("`name` is required.")
        }
        if service.collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return FontMCPTools.errorResult("A collection named '\(name)' already exists — use update_collection to add fonts to it.")
        }
        let (families, unknown) = resolveFamilies(FontMCPTools.stringArray(args["families"]), service: service)
        let collection = service.createCollection(named: name, families: families)
        return collectionResult(collection, service: service, unknown: unknown, summary: "Created collection '\(collection.name)' with \(families.count) family(ies).")
    }

    static func updateCollection(_ args: [String: Value], service: FontService) -> CallTool.Result {
        guard let name = args["name"]?.stringValue,
              let collection = service.collections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let existing = service.collections.map(\.name).joined(separator: ", ")
            return FontMCPTools.errorResult("No collection named '\(args["name"]?.stringValue ?? "")'. Existing: \(existing.isEmpty ? "none" : existing).")
        }
        if args["delete"]?.boolValue == true {
            service.deleteCollection(collection.id)
            return FontMCPTools.encoded(["deleted": collection.name], summary: "Deleted collection '\(collection.name)' (its fonts stay in the library).")
        }
        let (add, unknownAdd) = resolveFamilies(FontMCPTools.stringArray(args["add"]), service: service)
        let (remove, unknownRemove) = resolveFamilies(FontMCPTools.stringArray(args["remove"]), service: service)
        if !add.isEmpty { service.addFamilies(add, to: collection.id) }
        if !remove.isEmpty { service.removeFamilies(remove, from: collection.id) }
        if let newName = args["renameTo"]?.stringValue, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
            service.renameCollection(collection.id, to: newName)
        }
        let updated = service.collections.first { $0.id == collection.id } ?? collection
        return collectionResult(updated, service: service, unknown: unknownAdd + unknownRemove,
                                summary: "Updated '\(updated.name)': +\(add.count) / −\(remove.count).")
    }

    private static func collectionResult(_ collection: FontCollection, service: FontService, unknown: [String], summary: String) -> CallTool.Result {
        struct Result: Codable { let name: String; let families: [String]; let notFound: [String] }
        var text = summary
        if !unknown.isEmpty { text += " Not found (skipped): \(unknown.joined(separator: ", "))." }
        return FontMCPTools.encoded(Result(name: collection.name, families: collection.families, notFound: unknown), summary: text)
    }

    // MARK: - Activation

    static func setActive(_ args: [String: Value], service: FontService) -> CallTool.Result {
        guard let active = args["active"]?.boolValue else { return FontMCPTools.errorResult("`active` (true/false) is required.") }
        var names = FontMCPTools.stringArray(args["families"])
        if let collectionName = args["collection"]?.stringValue {
            guard let collection = service.collections.first(where: { $0.name.caseInsensitiveCompare(collectionName) == .orderedSame }) else {
                return FontMCPTools.errorResult("No collection named '\(collectionName)'.")
            }
            names += collection.families
        }
        let (families, unknown) = resolveFamilies(names, service: service)
        guard !families.isEmpty else { return FontMCPTools.errorResult("Pass `families` and/or `collection`.") }

        struct Outcome: Codable { let family: String; let active: Bool; let note: String? }
        var outcomes: [Outcome] = []
        for family in families {
            guard let font = service.fonts.first(where: { $0.familyName == family && $0.canToggleActivation }) else {
                let current = service.fonts.first { $0.familyName == family }
                outcomes.append(Outcome(family: family, active: current?.isActive ?? true, note: "managed by macOS (installed in a system font folder) — can't be toggled"))
                continue
            }
            let ok = active ? service.activateFont(font, notify: false) : service.deactivateFont(font, notify: false)
            let now = service.fonts.first { $0.id == font.id }?.isActive ?? font.isActive
            outcomes.append(Outcome(family: family, active: now, note: ok ? nil : "failed — see the app for details"))
        }
        struct Result: Codable { let results: [Outcome]; let notFound: [String] }
        let changed = outcomes.filter { $0.note == nil }.count
        return FontMCPTools.encoded(Result(results: outcomes, notFound: unknown),
                                    summary: "\(active ? "Activated" : "Deactivated") \(changed) of \(families.count) family(ies).")
    }

    // MARK: - Library

    static func refresh(service: FontService) -> CallTool.Result {
        service.loadAllFonts()
        return CallTool.Result(content: [.text("Rescanning the library (source folders and installed fonts). Results update in a few seconds; call find_fonts again afterwards.")])
    }

    // MARK: - Suggestions

    static func suggest(_ args: [String: Value], service: FontService) -> CallTool.Result {
        guard let items = args["suggestions"]?.arrayValue, !items.isEmpty else {
            return FontMCPTools.errorResult("`suggestions` is required: an array of { family, foundry?, classification?, width?, reason? }.")
        }
        var inputs: [FontService.SuggestionInput] = []
        for item in items {
            guard let obj = item.objectValue, let family = obj["family"]?.stringValue else { continue }
            let reason = obj["reason"]?.stringValue
            for field in AttributeSuggestion.Field.allCases {
                if let value = obj[field.rawValue]?.stringValue {
                    inputs.append(.init(family: family, field: field, value: value, reason: reason))
                }
            }
        }
        let outcome = service.submitSuggestions(inputs, source: args["source"]?.stringValue)
        struct Skip: Codable { let family, field, reason: String }
        struct Result: Codable { let queued: Int; let skipped: [Skip]; let pendingTotal: Int }
        let result = Result(queued: outcome.queued,
                            skipped: outcome.skipped.map { Skip(family: $0.family, field: $0.field, reason: $0.reason) },
                            pendingTotal: service.pendingSuggestions.count)
        return FontMCPTools.encoded(result, summary: "Queued \(outcome.queued) suggestion(s) for review. Ask the user to open Font Manager → Review Suggestions to accept or reject them; check outcomes with list_suggestions.")
    }

    static func listSuggestions(_ args: [String: Value], service: FontService) -> CallTool.Result {
        let status = args["status"]?.stringValue?.lowercased()
        struct Item: Codable { let family, field, value: String; let reason: String?; let status: String; let createdAt: String }
        let iso = ISO8601DateFormatter()
        let items = service.suggestions
            .filter { status == nil || $0.status.rawValue == status }
            .suffix(200)
            .map { Item(family: $0.family, field: $0.field.rawValue, value: $0.value, reason: $0.reason, status: $0.status.rawValue, createdAt: iso.string(from: $0.createdAt)) }
        struct Result: Codable { let pending: Int; let suggestions: [Item] }
        return FontMCPTools.encoded(Result(pending: service.pendingSuggestions.count, suggestions: Array(items)),
                                    summary: "\(service.pendingSuggestions.count) suggestion(s) awaiting review.")
    }

    // MARK: - Helpers

    /// Maps requested names to exact library family names (case-insensitive), deduped.
    private static func resolveFamilies(_ names: [String], service: FontService) -> (found: [String], unknown: [String]) {
        let byLower = Dictionary(service.fonts.map { ($0.familyName.lowercased(), $0.familyName) }, uniquingKeysWith: { a, _ in a })
        var found: [String] = [], unknown: [String] = []
        for name in names {
            if let family = byLower[name.lowercased()] {
                if !found.contains(family) { found.append(family) }
            } else { unknown.append(name) }
        }
        return (found, unknown)
    }
}
