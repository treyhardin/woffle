import SwiftUI
import TipKit

struct FontListView: View {
    @EnvironmentObject var fontService: FontService
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var chipTextSize: CGFloat = 15
    private let actionsTip = SidebarActionsTip()
    /// Natural height of the filters + collections block, measured so it can be capped.
    @State private var topSectionHeight: CGFloat = 0
    /// The filters/collections block never takes more than this share of the sidebar — past
    /// that it scrolls on its own, so the sidebar can't grow taller than the window (which
    /// would push the whole window's layout, main panel included, past its edges).
    private let topSectionMaxShare: CGFloat = 0.55

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                SidebarSearchField(text: $fontService.searchText, focused: $searchFocused)
                    .padding([.horizontal, .top], 8)
                    .padding(.bottom, 6)

                ScrollView {
                    topSection
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topSectionHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(topSectionHeight, geo.size.height * topSectionMaxShare))

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
        }
        .onChange(of: fontService.searchFocusToken) { _, _ in
            searchFocused = true
        }
    }

    /// Filters, collections, and the one-time sidebar tip.
    private var topSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
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
                    LabeledFilterSection(title: "Style", activeValue: fontService.filterClassification?.rawValue,
                                         expandedKey: "filters.styleExpanded") {
                        ForEach(fontService.availableClassifications) { classification in
                            FilterChip(label: classification == .symbol ? "✻ Symbol" : classification.rawValue,
                                       font: styleSpecimenFont(classification, size: chipTextSize),
                                       isOn: fontService.filterClassification == classification) {
                                fontService.filterClassification = fontService.filterClassification == classification ? nil : classification
                            }
                        }
                    }

                    if fontService.availableWidths.count > 1 {
                        LabeledFilterSection(title: "Width", activeValue: fontService.filterWidth?.rawValue,
                                             expandedKey: "filters.widthExpanded",
                                             columnCount: fontService.availableWidths.count) {
                            ForEach(fontService.availableWidths) { width in
                                FilterChip(label: width.rawValue,
                                           font: widthSpecimenFont(width, size: chipTextSize),
                                           isOn: fontService.filterWidth == width) {
                                    fontService.filterWidth = fontService.filterWidth == width ? nil : width
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Divider()

            SidebarLibrarySection()
                .padding(8)

            TipView(actionsTip)
                .padding([.horizontal, .bottom], 8)
        }
    }

    private var isEmptyCollection: Bool {
        fontService.activeCollection.map { fontService.count(in: $0) == 0 } ?? false
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            PhIcon(.magnifyingGlass, size: 26)
                .foregroundStyle(.tertiary)
            Text(isEmptyCollection ? "This collection is empty" : "No fonts match")
                .foregroundStyle(.secondary)
            if isEmptyCollection {
                Text("Drag fonts here, or right-click a font → Add to Collection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
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

/// A collapsible filter group: a header (with the active value, e.g. "STYLE · Serif") over
/// a two-column grid of labeled chips. Open/closed state is remembered per section.
struct LabeledFilterSection<Content: View>: View {
    let title: String
    var activeValue: String? = nil
    @AppStorage private var isExpanded: Bool
    @ViewBuilder var content: Content

    private let columns: [GridItem]

    init(title: String, activeValue: String? = nil, expandedKey: String, columnCount: Int = 2, @ViewBuilder content: () -> Content) {
        self.title = title
        self.activeValue = activeValue
        _isExpanded = AppStorage(wrappedValue: true, expandedKey)
        columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title.uppercased())
                        .foregroundStyle(.secondary)
                    if let activeValue {
                        Text("· \(activeValue)")
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    PhIcon(.caretDown, size: 11)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .font(.caption2)
                .fontWeight(.semibold)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) filters")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 6) { content }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A filter toggle whose label is set in a typeface that shows what it filters for
/// ("Script" in a script face, "Condensed" in a condensed cut).
struct FilterChip: View {
    let label: String
    let font: Font
    let isOn: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    isOn ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing \(label) only — click to clear" : "Show only \(label)")
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

/// A representative typeface for each classification, used for the Style chip labels. All
/// ship with macOS except Pirata One (SIL OFL), bundled for Blackletter since macOS has none.
func styleSpecimenFont(_ classification: FontClassification, size: CGFloat) -> Font {
    switch classification {
    case .serif: return .system(size: size, design: .serif).weight(.medium)
    case .sansSerif: return .system(size: size, design: .default).weight(.medium)
    case .slabSerif: return .custom("Rockwell", size: size)
    // Script faces run small for their point size; nudge up so the label reads at a glance.
    case .script: return .custom("Snell Roundhand", size: size * 1.2).weight(.semibold)
    case .monospaced: return .system(size: size, design: .monospaced)
    case .blackletter: return BundledFonts.pirataOne(size: size * 1.15)
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
        .draggable(font.familyName)   // drop onto a sidebar collection to add it
        .contextMenu { FontContextMenu(font: font) }
    }
}

/// Right-click actions for a font (sidebar rows and browse cards). When the font is part of
/// a multi-selection, collection actions apply to the whole selection.
struct FontContextMenu: View {
    @EnvironmentObject var fontService: FontService
    let font: FontItem

    private var targets: [FontItem] {
        guard fontService.selection.count > 1, fontService.selection.contains(font.id) else { return [font] }
        return fontService.fonts.filter { fontService.selection.contains($0.id) }
    }

    var body: some View {
        if font.canToggleActivation {
            Button(font.isActive ? "Deactivate" : "Activate") {
                fontService.toggleFont(font)
            }
        }
        // Selects every file backing the family (deduped — styles can share one .ttc).
        let fileURLs = Array(Set(font.members.compactMap(\.fileURL)))
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
        }
        .disabled(fileURLs.isEmpty)
        Divider()
        CollectionMenuItems(fonts: targets)
        if case .imported = font.source {
            Divider()
            Button("Remove from Library", role: .destructive) {
                fontService.removeImportedFont(font)
            }
        }
    }
}
