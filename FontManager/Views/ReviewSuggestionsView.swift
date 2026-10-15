import SwiftUI

/// Toolbar button shown while AI tools have suggestions waiting; opens the review sheet.
struct ReviewSuggestionsButton: View {
    @EnvironmentObject var fontService: FontService
    @State private var showingReview = false

    var body: some View {
        let count = fontService.pendingSuggestions.count
        if count > 0 {
            Button {
                showingReview = true
            } label: {
                PhLabel("Review \(count)", icon: .sparkle)
                    .padding(.horizontal, 6)
            }
            .labelStyle(.titleAndIcon)
            .help("\(count) suggested change\(count == 1 ? "" : "s") from AI tools")
            .sheet(isPresented: $showingReview) {
                ReviewSuggestionsView()
                    .environmentObject(fontService)
            }
        }
    }
}

/// Accept or reject attribute changes proposed by AI tools, grouped by font.
struct ReviewSuggestionsView: View {
    @EnvironmentObject var fontService: FontService
    @Environment(\.dismiss) private var dismiss

    private var groups: [(family: String, items: [AttributeSuggestion])] {
        let pending = fontService.pendingSuggestions
        let families = pending.map(\.family).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return families.map { family in (family, pending.filter { $0.family == family }) }
    }

    private var sources: String {
        let names = Set(fontService.pendingSuggestions.compactMap(\.source))
        return names.isEmpty ? "an AI tool" : names.sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Suggestions")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(fontService.pendingSuggestions.count) change\(fontService.pendingSuggestions.count == 1 ? "" : "s") to \(groups.count) font\(groups.count == 1 ? "" : "s"), suggested by \(sources). Nothing changes until you accept.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    PhIcon(.checkCircle, size: 32).foregroundStyle(.green)
                    Text("All caught up").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.family) { group in
                        Section {
                            ForEach(group.items) { suggestion in
                                SuggestionRow(suggestion: suggestion)
                            }
                        } header: {
                            familyHeader(group.family)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Reject All") { fontService.reject(Set(fontService.pendingSuggestions.map(\.id))) }
                    .disabled(groups.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept All") { fontService.accept(Set(fontService.pendingSuggestions.map(\.id))) }
                    .buttonStyle(.borderedProminent)
                    .disabled(groups.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 520)
    }

    /// The family name set in its own typeface, so you can judge the label at a glance.
    private func familyHeader(_ family: String) -> some View {
        let font = fontService.fonts.first { $0.familyName == family }
        return Text(family)
            .font(font?.members.first.map { FontPreview.font(for: $0, size: 18, isActive: font?.isActive ?? true) } ?? .headline)
            .foregroundStyle(.primary)
            .textCase(nil)
            .lineLimit(1)
    }
}

private struct SuggestionRow: View {
    @EnvironmentObject var fontService: FontService
    let suggestion: AttributeSuggestion

    private var currentValue: String {
        guard let font = fontService.fonts.first(where: { $0.familyName == suggestion.family }) else { return "—" }
        switch suggestion.field {
        case .foundry: return fontService.displayFoundry(font)
        case .classification: return fontService.effectiveClassification(font).rawValue
        case .width: return fontService.effectiveWidth(font).rawValue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(currentValue)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    Text("→").foregroundStyle(.tertiary)
                    Text(suggestion.value).fontWeight(.semibold)
                }
                if let reason = suggestion.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 62)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Reject") { fontService.reject([suggestion.id]) }
                .controlSize(.small)
            Button("Accept") { fontService.accept([suggestion.id]) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 3)
    }
}
