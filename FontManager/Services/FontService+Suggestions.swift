import Foundation

/// An attribute change proposed by an AI tool, waiting for the user to accept or reject it
/// in the Review Suggestions sheet. One per family + field, so each can be decided alone.
struct AttributeSuggestion: Identifiable, Codable, Hashable {
    enum Field: String, Codable, CaseIterable {
        case foundry, classification, width

        /// UI name — the app calls classification "Style".
        var label: String {
            switch self {
            case .foundry: return "Foundry"
            case .classification: return "Style"
            case .width: return "Width"
            }
        }
    }
    enum Status: String, Codable { case pending, accepted, rejected }

    let id: UUID
    let family: String
    let field: Field
    let value: String
    let reason: String?
    /// Who suggested it (e.g. "Claude"), as the tool reported.
    let source: String?
    let createdAt: Date
    var status: Status
}

/// Suggestions: agents propose, the user decides. Persisted to `suggestions.json`.
extension FontService {
    var pendingSuggestions: [AttributeSuggestion] { suggestions.filter { $0.status == .pending } }

    struct SuggestionInput {
        let family: String
        let field: AttributeSuggestion.Field
        let value: String
        let reason: String?
    }

    /// Queues suggestions, replacing any pending one for the same family + field. Returns
    /// the ones skipped, with why (unknown family, invalid value, already the current value).
    @discardableResult
    func submitSuggestions(_ inputs: [SuggestionInput], source: String?) -> (queued: Int, skipped: [(family: String, field: String, reason: String)]) {
        var queued = 0
        var skipped: [(String, String, String)] = []
        for input in inputs {
            guard let font = fonts.first(where: { $0.familyName == input.family }) else {
                skipped.append((input.family, input.field.rawValue, "no family with that exact name"))
                continue
            }
            let current: String
            switch input.field {
            case .foundry:
                current = effectiveFoundry(font) ?? ""
            case .classification:
                guard FontClassification(rawValue: input.value) != nil else {
                    skipped.append((input.family, "classification", "invalid value '\(input.value)'")); continue
                }
                current = effectiveClassification(font).rawValue
            case .width:
                guard FontWidth(rawValue: input.value) != nil else {
                    skipped.append((input.family, "width", "invalid value '\(input.value)'")); continue
                }
                current = effectiveWidth(font).rawValue
            }
            if current == input.value {
                skipped.append((input.family, input.field.rawValue, "already '\(current)'")); continue
            }
            suggestions.removeAll { $0.status == .pending && $0.family == input.family && $0.field == input.field }
            suggestions.append(AttributeSuggestion(id: UUID(), family: input.family, field: input.field, value: input.value,
                                                   reason: input.reason, source: source, createdAt: Date(), status: .pending))
            queued += 1
        }
        saveSuggestions()
        return (queued, skipped)
    }

    func accept(_ ids: Set<UUID>) {
        for index in suggestions.indices where ids.contains(suggestions[index].id) && suggestions[index].status == .pending {
            let suggestion = suggestions[index]
            guard let font = fonts.first(where: { $0.familyName == suggestion.family }) else { continue }
            switch suggestion.field {
            case .foundry: setFoundryOverride(suggestion.value, for: font)
            case .classification: FontClassification(rawValue: suggestion.value).map { setClassificationOverride($0, for: font) }
            case .width: FontWidth(rawValue: suggestion.value).map { setWidthOverride($0, for: font) }
            }
            suggestions[index].status = .accepted
        }
        saveSuggestions()
    }

    func reject(_ ids: Set<UUID>) {
        for index in suggestions.indices where ids.contains(suggestions[index].id) && suggestions[index].status == .pending {
            suggestions[index].status = .rejected
        }
        saveSuggestions()
    }

    // MARK: - Persistence

    private var suggestionsURL: URL { AppEnvironment.supportDirectory.appendingPathComponent("suggestions.json") }

    func loadSuggestions() {
        guard let data = try? Data(contentsOf: suggestionsURL),
              let decoded = try? JSONDecoder().decode([AttributeSuggestion].self, from: data) else { return }
        suggestions = decoded
    }

    private func saveSuggestions() {
        // Keep every pending suggestion plus the most recent 500 decisions (agents can
        // check outcomes via list_suggestions).
        let decided = suggestions.filter { $0.status != .pending }.suffix(500)
        suggestions = suggestions.filter { $0.status == .pending } + decided
        guard let data = try? JSONEncoder().encode(suggestions) else { return }
        try? data.write(to: suggestionsURL, options: .atomic)
    }
}
