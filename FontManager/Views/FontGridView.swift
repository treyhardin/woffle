import SwiftUI

/// How the browse pane lays out families: specimen cards or full-width rows.
enum FontBrowseLayout: String {
    case grid
    case list
}

/// The default detail view when nothing is selected: a browsable view of the same fonts
/// shown in the sidebar (filters applied). Toggles between specimen cards (grid) and
/// full-width rows (list). Clicking a font selects that family and switches to the detail view.
struct FontGridView: View {
    @EnvironmentObject var fontService: FontService
    /// Custom specimen text; blank shows each family's name. Persisted, separate from the
    /// detail view's own sample text so the grid keeps its font-name default.
    @AppStorage("grid.previewText") private var previewText: String = ""
    /// Grid vs. list layout, persisted across launches.
    @AppStorage("grid.layout") private var layoutRaw: String = FontBrowseLayout.grid.rawValue
    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    private var layout: FontBrowseLayout {
        FontBrowseLayout(rawValue: layoutRaw) ?? .grid
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AccessNeededBanner()
            GetStartedBanner()
            if fontService.filteredFonts.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    Group {
                        switch layout {
                        case .grid: gridContent
                        case .list: listContent
                        }
                    }
                    // Letters only group under the name sorts.
                    .alphabetScrubber(fonts: fontService.sortOrder == .mostRecent ? [] : fontService.browseFonts,
                                      proxy: proxy,
                                      descending: fontService.sortOrder == .nameDescending)
                }
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(fontService.browseFonts) { font in
                    FontCardView(font: font, previewText: previewText)
                }
            }
            .padding(20)
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(fontService.browseFonts) { font in
                    FontRowLargeView(font: font, previewText: previewText)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            previewInput
            SortMenu(selection: $fontService.sortOrder)
            LayoutToggle(layout: $layoutRaw)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var previewInput: some View {
        HStack(spacing: 8) {
            PhIcon(.textAa, size: 15)
                .foregroundStyle(.secondary)
            TextField("Preview text — leave blank to show font names", text: $previewText)
                .textFieldStyle(.plain)
                .onExitCommand { previewText = "" }
            if !previewText.isEmpty {
                Button {
                    previewText = ""
                } label: {
                    PhIcon(.xCircle, size: 15).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear preview text")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if let collection = fontService.activeCollection, fontService.count(in: collection) == 0 {
                PhIcon(collection.isSmart ? .funnel : .folderSimple, size: 40)
                    .foregroundStyle(.tertiary)
                Text(collection.isSmart ? "No fonts match \(collection.name)" : "\(collection.name) is empty")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(collection.isSmart
                     ? "Fonts matching its rules appear here automatically. Right-click it in the sidebar to edit the rules."
                     : "Drag fonts onto it in the sidebar, or right-click any font → Add to Collection.")
                    .foregroundStyle(.tertiary)
                if collection.isSmart {
                    Button("Edit Smart Collection…") {
                        fontService.smartCollectionEditor = SmartCollectionEditorRequest(collection: collection)
                    }
                }
            } else {
                PhIcon(fontService.hasActiveFilters ? .funnel : .textAa, size: 40)
                    .foregroundStyle(.tertiary)
                Text(fontService.hasActiveFilters ? "No fonts match your filters" : "No fonts found")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if fontService.hasActiveFilters {
                Button("Clear Filters") { fontService.clearFilters() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A compact dropdown for the browse pane's order, styled to sit beside the layout toggle.
struct SortMenu: View {
    @Binding var selection: FontService.SortOrder

    var body: some View {
        Menu {
            ForEach(FontService.SortOrder.allCases) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.rawValue)
                    .foregroundStyle(.primary)
                PhIcon(.caretUpDown, size: 13)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort fonts")
    }
}

/// A two-segment control switching the browse pane between grid (cards) and list (rows).
struct LayoutToggle: View {
    @Binding var layout: String

    var body: some View {
        HStack(spacing: 2) {
            segment(.grid, icon: .squaresFour, help: "Grid view")
            segment(.list, icon: .list, help: "List view")
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(_ mode: FontBrowseLayout, icon: Ph, help: String) -> some View {
        let isOn = layout == mode.rawValue
        return Button {
            layout = mode.rawValue
        } label: {
            PhIcon(icon, size: 15)
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: 30, height: 24)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A full-width browse row: a large specimen set in the family's own typeface, a metadata
/// caption, and an activation indicator. The whole row is a button that selects the family.
struct FontRowLargeView: View {
    @EnvironmentObject var fontService: FontService
    let font: FontItem
    var previewText: String = ""
    @State private var hovering = false
    @ScaledMetric(relativeTo: .title3) private var specimenSize: CGFloat = 24

    var body: some View {
        Button {
            fontService.selection = [font.id]
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(previewText.isEmpty ? font.familyName : previewText)
                        .font(font.members.first.map { FontPreview.font(for: $0, size: specimenSize, isActive: font.isActive) } ?? .system(size: specimenSize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    HStack(spacing: 4) {
                        // Always name the font — the specimen above may show custom preview text.
                        Text(font.familyName)
                        if let foundry = font.foundry {
                            Text("·")
                            Text(foundry)
                        }
                        Text("·")
                        Text("\(font.members.count) style\(font.members.count == 1 ? "" : "s")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ActivationDot(isActive: font.isActive)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.secondary.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(font.familyName)")
        .draggable(font.familyName)   // drop onto a sidebar collection to add it
        .contextMenu { FontContextMenu(font: font) }
    }
}

/// A "‹ All Fonts" control shown atop a detail view; clears the selection to return to
/// the grid. Also bound to ⌘[ so there's always a way back.
struct BackToGridButton: View {
    @EnvironmentObject var fontService: FontService

    var body: some View {
        Button {
            fontService.selection = []
        } label: {
            PhLabel("All Fonts", icon: .caretLeft)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Back to all fonts")
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// A specimen card: the family name set in its own typeface, with a metadata caption and
/// activation indicator. The whole card is a button that selects the family.
struct FontCardView: View {
    @EnvironmentObject var fontService: FontService
    let font: FontItem
    var previewText: String = ""
    @State private var hovering = false
    @ScaledMetric(relativeTo: .title2) private var specimenSize: CGFloat = 30

    var body: some View {
        Button {
            fontService.selection = [font.id]
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(previewText.isEmpty ? font.familyName : previewText)
                    .font(font.members.first.map { FontPreview.font(for: $0, size: specimenSize, isActive: font.isActive) } ?? .system(size: specimenSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)

                HStack(spacing: 4) {
                    // Always name the font — the specimen above may show custom preview text.
                    Text(font.familyName)
                    if let foundry = font.foundry {
                        Text("·")
                        Text(foundry)
                    }
                    Text("·")
                    Text("\(font.members.count) style\(font.members.count == 1 ? "" : "s")")
                    Spacer(minLength: 4)
                    ActivationDot(isActive: font.isActive)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: hovering ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(font.familyName)")
        .draggable(font.familyName)   // drop onto a sidebar collection to add it
        .contextMenu { FontContextMenu(font: font) }
    }
}
