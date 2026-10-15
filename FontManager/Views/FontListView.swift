import SwiftUI

struct FontListView: View {
    @EnvironmentObject var fontService: FontService
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var styleGlyphSize: CGFloat = 15
    var body: some View {
        VStack(spacing: 0) {
            // Compact filter header
            VStack(spacing: 6) {
                SidebarSearchField(text: $fontService.searchText, focused: $searchFocused)

                // Filter inputs stack full-width, each showing its selected value
                // ("Foundry     All"), so the current state is always visible at a glance.
                FilterMenuPicker(title: "Status", selection: $fontService.filterStatus) { status in
                    fontService.count(for: status)
                }
                if fontService.availableFoundries.count > 1 {
                    FoundryFilterMenu()
                }

                // Style/Width are unresolved when filtering to "Missing Info", so hide them there.
                if fontService.filterStatus != .missingInfo {
                    FilterSection(title: "Style", activeValue: fontService.filterClassification?.rawValue) {
                        ForEach(fontService.availableClassifications) { classification in
                            FilterIconButton(
                                isOn: fontService.filterClassification == classification,
                                help: classification.rawValue
                            ) {
                                fontService.filterClassification = fontService.filterClassification == classification ? nil : classification
                            } label: {
                                Text(classification == .symbol ? "✻" : "Ag")
                                    .font(styleSpecimenFont(classification, size: styleGlyphSize))
                                    .minimumScaleFactor(0.5)
                                    .lineLimit(1)
                                    // Center each specimen on its text baseline (not its line
                                    // box) so differing font metrics — e.g. Rockwell for slab
                                    // serif — don't sit higher or lower than the others.
                                    .alignmentGuide(VerticalAlignment.center) { dims in
                                        dims[.firstTextBaseline] - styleGlyphSize * 0.25
                                    }
                            }
                        }
                    }

                    if fontService.availableWidths.count > 1 {
                        FilterSection(title: "Width", activeValue: fontService.filterWidth?.rawValue) {
                            ForEach(fontService.availableWidths) { width in
                                FilterIconButton(
                                    isOn: fontService.filterWidth == width,
                                    help: width.rawValue
                                ) {
                                    fontService.filterWidth = fontService.filterWidth == width ? nil : width
                                } label: {
                                    Text("Ag")
                                        .font(widthSpecimenFont(width, size: styleGlyphSize))
                                        .minimumScaleFactor(0.5)
                                        .lineLimit(1)
                                        .alignmentGuide(VerticalAlignment.center) { dims in
                                            dims[.firstTextBaseline] - styleGlyphSize * 0.25
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)

            Divider()

            if fontService.filteredFonts.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List(fontService.filteredFonts, selection: $fontService.selection) { font in
                        FontRowView(font: font)
                    }
                    .listStyle(.sidebar)
                    .alphabetScrubber(fonts: fontService.filteredFonts, proxy: proxy)
                }
            }

            Divider()
            footer
        }
        .onChange(of: fontService.searchFocusToken) { _, _ in
            searchFocused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            PhIcon(.magnifyingGlass, size: 26)
                .foregroundStyle(.tertiary)
            Text("No fonts match")
                .foregroundStyle(.secondary)
            if fontService.hasActiveFilters {
                Button("Clear Filters") { fontService.clearFilters() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            Text("\(fontService.filteredFonts.count) families")
            Spacer()
            if fontService.hasActiveFilters {
                Button("Clear") { fontService.clearFilters() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// A search field styled to sit at the top of the sidebar.
struct SidebarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            PhIcon(.magnifyingGlass, size: 14)
                .foregroundStyle(.secondary)
            TextField("Search fonts", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    PhIcon(.xCircle, size: 15)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A full-width menu label showing a field's name on the left and its current value on
/// the right ("Foundry     All"), drawn as a bordered field to match the search box above.
struct FilterMenuLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
            PhIcon(.caretUpDown, size: 13)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Makes a `.menuStyle(.button)` menu fill the sidebar width (the default bordered button
/// style hugs its content). Styling lives on the label; this just stretches + dims on press.
struct FilterFieldMenuStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A self-describing, full-width sidebar dropdown that shows its selected value
/// ("Status     All"). Used for Status in the sidebar.
struct FilterMenuPicker<T>: View where T: CaseIterable & Hashable & RawRepresentable, T.RawValue == String {
    let title: String
    @Binding var selection: T
    /// Optional count shown after an option in the open menu (e.g. "Missing Info (437)").
    var badge: ((T) -> Int?)? = nil

    var body: some View {
        Menu {
            ForEach(Array(T.allCases), id: \.self) { option in
                let label = badge?(option).map { "\(option.rawValue) (\($0))" } ?? option.rawValue
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            FilterMenuLabel(title: title, value: selection.rawValue)
        }
        .menuStyle(.button)
        .buttonStyle(FilterFieldMenuStyle())
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

/// A self-describing dropdown to filter the list by type foundry (e.g. "Foundry · Klim
/// Type Foundry"). Dynamic option list, so it can't reuse the enum-based FilterMenuPicker.
struct FoundryFilterMenu: View {
    @EnvironmentObject var fontService: FontService

    var body: some View {
        Menu {
            Button {
                fontService.filterFoundry = nil
            } label: {
                if fontService.filterFoundry == nil {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }
            Divider()
            ForEach(fontService.availableFoundries, id: \.self) { name in
                Button {
                    fontService.filterFoundry = name
                } label: {
                    let label = "\(name) (\(fontService.count(forFoundry: name)))"
                    if fontService.filterFoundry == name {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            FilterMenuLabel(title: "Foundry", value: fontService.filterFoundry ?? "All")
        }
        .menuStyle(.button)
        .buttonStyle(FilterFieldMenuStyle())
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

/// A titled group of filter buttons that wraps onto multiple rows when it can't fit,
/// so the sidebar never needs horizontal scrolling and content never overflows its width.
/// When a value is selected, the title shows it (e.g. "STYLE · Serif") so the
/// otherwise-unlabeled specimen glyphs are legible once chosen.
struct FilterSection<Content: View>: View {
    let title: String
    var activeValue: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .foregroundStyle(.secondary)
                if let activeValue {
                    Text("· \(activeValue)")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption2)
            .fontWeight(.semibold)
            FlowLayout(spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Left-to-right wrapping layout: places children on a row until the next one would
/// overflow the proposed width, then wraps. Keeps filter chips fully visible at any
/// sidebar width without horizontal scrolling.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widestRow = max(widestRow, x - spacing)
        }

        let width = maxWidth == .infinity ? widestRow : maxWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A square toggle button used by the Style and Width filters.
struct FilterIconButton<Label: View>: View {
    let isOn: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label

    // Scales the button with the user's text-size preference.
    @ScaledMetric(relativeTo: .body) private var dimension: CGFloat = 29

    var body: some View {
        Button(action: action) {
            label
                .frame(width: dimension, height: dimension)
                .background(
                    isOn ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Activation indicator: filled = active, outlined = inactive (a shape cue, not just color).
struct ActivationDot: View {
    let isActive: Bool

    var body: some View {
        Group {
            if isActive {
                Circle().fill(Color.green)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel(isActive ? "Active" : "Inactive")
    }
}

/// A representative typeface for each classification, used as the Style button glyph.
func styleSpecimenFont(_ classification: FontClassification, size: CGFloat) -> Font {
    switch classification {
    case .serif: return .system(size: size, design: .serif).weight(.semibold)
    case .sansSerif: return .system(size: size, design: .default).weight(.semibold)
    case .slabSerif: return .custom("Rockwell", size: size)
    case .script: return .custom("Snell Roundhand", size: size)
    // Courier's typewriter forms read unmistakably as monospace at a glance —
    // clearer than SF Mono, whose "Ag" looks like a plain sans.
    case .monospaced: return .custom("Courier New", size: size).weight(.bold)
    // No blackletter ships with macOS; a heavy serif is the least-misleading stand-in glyph.
    case .blackletter: return .system(size: size, design: .serif).weight(.heavy)
    case .symbol, .unclassified: return .system(size: size)
    }
}

/// Skia (a macOS system typeface) ships genuine condensed/regular/extended width cuts, so
/// one typeface renders all three Width glyphs — cleaner than horizontally scaling a font.
func widthSpecimenFont(_ width: FontWidth, size: CGFloat) -> Font {
    switch width {
    case .condensed: return .custom("Skia-Regular_Condensed", size: size)
    case .regular: return .custom("Skia-Regular", size: size)
    case .expanded: return .custom("Skia-Regular_Extended", size: size)
    }
}

struct FontRowView: View {
    @EnvironmentObject var fontService: FontService
    let font: FontItem
    @ScaledMetric(relativeTo: .body) private var previewSize: CGFloat = 14

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(font.familyName)
                    .font(font.members.first.map { FontPreview.font(for: $0, size: previewSize, isActive: font.isActive) } ?? .system(size: previewSize))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    let classification = fontService.effectiveClassification(font)
                    if classification != .unclassified {
                        Text(classification.rawValue)
                        if fontService.isOverridden(font) {
                            PhIcon(.pencilSimple, size: 12)
                                .accessibilityLabel("Overridden")
                        }
                        Text("·")
                    }
                    Text("\(font.members.count) style\(font.members.count == 1 ? "" : "s")")
                    if case .imported = font.source {
                        Text("·")
                        Text("Imported")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            ActivationDot(isActive: font.isActive)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(font.isActive ? "Deactivate" : "Activate") {
                fontService.toggleFont(font)
            }
            // Selects every file backing the family (deduped — styles can share one .ttc).
            let fileURLs = Array(Set(font.members.compactMap(\.fileURL)))
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
            }
            .disabled(fileURLs.isEmpty)
            if case .imported = font.source {
                Divider()
                Button("Remove from Library", role: .destructive) {
                    fontService.removeImportedFont(font)
                }
            }
        }
    }
}
