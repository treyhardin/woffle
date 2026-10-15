import SwiftUI

/// Create or edit a smart collection: a name plus any combination of Style, Width and
/// Foundry. Within a category any selected value matches; categories combine with AND; an
/// empty category means "any". The match count updates live as you choose.
struct SmartCollectionEditor: View {
    @EnvironmentObject var fontService: FontService
    @Environment(\.dismiss) private var dismiss
    let existing: FontCollection?

    @State private var name: String
    @State private var rules: SmartCollectionRules
    @ScaledMetric(relativeTo: .body) private var chipTextSize: CGFloat = 15

    init(existing: FontCollection?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _rules = State(initialValue: existing?.rules ?? SmartCollectionRules())
    }

    private var matchCount: Int { fontService.fonts.filter { fontService.matches($0, rules) }.count }
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(existing == nil ? "New Smart Collection" : "Edit Smart Collection")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Fonts that match are added automatically — including ones you add later.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Name", text: $name, prompt: Text("e.g. Condensed Serifs"))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)

                    section("Style", note: rules.classifications.isEmpty ? "Any style" : nil) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(FontClassification.allCases.filter { $0 != .unclassified }) { classification in
                                FilterChip(label: classification == .symbol ? "✻ Symbol" : classification.rawValue,
                                           font: styleSpecimenFont(classification, size: chipTextSize),
                                           opticalCenter: opticalCenter(of: styleSpecimenCTFont(classification, size: chipTextSize)),
                                           isOn: rules.classifications.contains(classification)) {
                                    rules.classifications.formSymmetricDifference([classification])
                                }
                            }
                        }
                    }

                    section("Width", note: rules.widths.isEmpty ? "Any width" : nil) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(FontWidth.allCases) { width in
                                FilterChip(label: width.rawValue,
                                           font: widthSpecimenFont(width, size: chipTextSize),
                                           opticalCenter: opticalCenter(of: widthSpecimenCTFont(width, size: chipTextSize)),
                                           isOn: rules.widths.contains(width)) {
                                    rules.widths.formSymmetricDifference([width])
                                }
                            }
                        }
                    }

                    section("Foundry", note: rules.foundries.isEmpty ? "Any foundry" : nil) {
                        foundryPicker
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Matches \(matchCount.formatted()) font\(matchCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 640)
    }

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if let note {
                    Text("· \(note)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    /// "Any Foundry" plus every foundry, multi-select, in a scrolling box.
    private var foundryPicker: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                foundryRow("Any Foundry", isOn: rules.foundries.isEmpty) { rules.foundries = [] }
                ForEach(fontService.availableFoundries, id: \.self) { foundry in
                    foundryRow(foundry, count: fontService.count(forFoundry: foundry), isOn: rules.foundries.contains(foundry)) {
                        rules.foundries.formSymmetricDifference([foundry])
                    }
                }
            }
            .padding(4)
        }
        .frame(height: 9 * 26 + 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func foundryRow(_ title: String, count: Int? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PhIcon(isOn ? .checkSquare : .square, size: 16)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        if let existing {
            fontService.updateSmartCollection(existing.id, name: name, rules: rules)
        } else {
            let collection = fontService.createSmartCollection(named: name, rules: rules)
            fontService.filterStatus = .all
            fontService.activeCollectionID = collection.id
        }
        dismiss()
    }
}
