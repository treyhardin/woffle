import SwiftUI
import TipKit

struct FontListView: View {
    @EnvironmentObject var fontService: FontService
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var chipTextSize: CGFloat = 15
    private let actionsTip = SidebarActionsTip()

    /// The sidebar holds only search, filters and collections; the fonts themselves are in
    /// the browse grid, or the font list column once a font is open (see ContentView).
    var body: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $fontService.searchText, focused: $searchFocused)
                .padding([.horizontal, .top], 8)
                .padding(.bottom, 6)

            // Normally the Foundry list stretches to fill the leftover height, so the sidebar
            // itself never scrolls. If the window is too short for even a few foundry rows, fall
            // back to scrolling the whole sidebar rather than overflowing the window.
            ViewThatFits(in: .vertical) {
                topSection(foundryFills: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                ScrollView {
                    topSection(foundryFills: false)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()
            footer
        }
        .onChange(of: fontService.searchFocusToken) { _, _ in
            searchFocused = true
        }
    }

    /// Collections (incl. the fixed All / Active / Inactive / Missing Info), then the filters:
    /// Style, Width, Foundry. Everything is exposed — the sidebar is dedicated to filtering.
    private func topSection(foundryFills: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarLibrarySection()

            TipView(actionsTip)

            Divider()

            // Style/Width are unresolved when filtering to "Missing Info", so hide them there.
            if fontService.filterStatus != .missingInfo {
                LabeledFilterSection(title: "Style", activeValue: fontService.filterClassification?.rawValue,
                                     expandedKey: "filters.styleExpanded") {
                    ForEach(fontService.availableClassifications) { classification in
                        FilterChip(label: classification == .symbol ? "✻ Symbol" : classification.rawValue,
                                   font: styleSpecimenFont(classification, size: chipTextSize),
                                   opticalCenter: opticalCenter(of: styleSpecimenCTFont(classification, size: chipTextSize)),
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
                                       opticalCenter: opticalCenter(of: widthSpecimenCTFont(width, size: chipTextSize)),
                                       isOn: fontService.filterWidth == width) {
                                fontService.filterWidth = fontService.filterWidth == width ? nil : width
                            }
                        }
                    }
                }
            }

            if fontService.availableFoundries.count > 1 {
                LabeledFilterSection(title: "Foundry", activeValue: fontService.filterFoundry,
                                     expandedKey: "filters.foundryExpanded", columnCount: 0) {
                    FoundryList(fills: foundryFills)
                }
                .frame(maxHeight: foundryFills ? .infinity : nil, alignment: .top)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
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

/// Every foundry in a fixed-height scrolling box (about nine rows visible), "All Foundries"
/// first and selected by default. Click a foundry to filter to it; click again to clear.
struct FoundryList: View {
    @EnvironmentObject var fontService: FontService
    /// Stretch to the available height (scrolling inside) instead of a fixed nine rows.
    var fills = false
    private let rowHeight: CGFloat = 24
    private let visibleRows = 9
    /// The fewest rows worth showing before the sidebar falls back to scrolling as a whole.
    private let minimumRows = 4

    var body: some View {
        let foundries = fontService.availableFoundries
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    row(title: "All Foundries", count: fontService.fonts.count, isOn: fontService.filterFoundry == nil) {
                        fontService.filterFoundry = nil
                    }
                    ForEach(foundries, id: \.self) { name in
                        row(title: name, count: fontService.count(forFoundry: name), isOn: fontService.filterFoundry == name) {
                            fontService.filterFoundry = fontService.filterFoundry == name ? nil : name
                        }
                        .id(name)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: fills ? CGFloat(minimumRows) * rowHeight + 8 : nil,
                   idealHeight: fills ? CGFloat(minimumRows) * rowHeight + 8 : nil,
                   maxHeight: fills ? .infinity : nil)
            .frame(height: fills ? nil : CGFloat(min(foundries.count + 1, visibleRows)) * rowHeight + 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .onAppear { if let selected = fontService.filterFoundry { proxy.scrollTo(selected, anchor: .center) } }
        }
    }

    private func row(title: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .foregroundStyle(isOn ? Color.white.opacity(0.85) : .secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .background(isOn ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A collapsible filter group: a header (with the active value, e.g. "STYLE · Serif") over
/// a grid of labeled chips (`columnCount`), or the content as-is when `columnCount` is 0.
/// Open/closed state is remembered per section.
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
                Group {
                    if columns.isEmpty {
                        content
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) { content }
                    }
                }
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
    /// Height above the baseline to center on (see `opticalCenter(of:)`); fonts' line boxes
    /// sit their letters at different heights, so centering the box isn't enough.
    var opticalCenter: CGFloat? = nil
    let isOn: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .alignmentGuide(VerticalAlignment.center) { dims in
                    guard let opticalCenter else { return dims[VerticalAlignment.center] }
                    return dims[.firstTextBaseline] - opticalCenter
                }
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

/// The CoreText face behind each Style chip label (matches `styleSpecimenFont`), for metrics.
func styleSpecimenCTFont(_ classification: FontClassification, size: CGFloat) -> CTFont? {
    switch classification {
    case .serif:
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    case .sansSerif: return NSFont.systemFont(ofSize: size, weight: .medium)
    case .slabSerif: return NSFont(name: "Rockwell", size: size)
    case .script: return NSFont(name: "SnellRoundhand-Bold", size: size * 1.2) ?? NSFont(name: "Snell Roundhand", size: size * 1.2)
    case .monospaced: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    case .blackletter: return BundledFonts.pirataOneCTFont(size: size * 1.15)
    case .symbol, .unclassified: return NSFont.systemFont(ofSize: size)
    }
}

func widthSpecimenCTFont(_ width: FontWidth, size: CGFloat) -> CTFont? {
    switch width {
    case .condensed: return NSFont(name: "Skia-Regular_Condensed", size: size)
    case .regular: return NSFont(name: "Skia-Regular", size: size)
    case .expanded: return NSFont(name: "Skia-Regular_Extended", size: size)
    }
}

/// Where a label's letters visually sit above the baseline: midway between half the cap
/// height and half the x-height, which suits mixed-case words like "Slab Serif".
func opticalCenter(of font: CTFont?) -> CGFloat? {
    guard let font else { return nil }
    return (CTFontGetCapHeight(font) + CTFontGetXHeight(font)) / 4
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
