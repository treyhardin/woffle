import SwiftUI

/// Sidebar collections, directly under search:
/// - **Fixed** (always shown, can't be deleted): All Fonts, Active, Inactive, Missing Info.
/// - **Smart** collections (funnel icon): every font matching their rules, updated live.
/// - **Manual** collections (folder icon): fonts you add — drag fonts onto one to add them.
/// Picking any of them scopes the browse grid and the font list.
struct SidebarLibrarySection: View {
    @EnvironmentObject var fontService: FontService
    /// Past this many user collections the list scrolls rather than pushing the filters down.
    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("COLLECTIONS")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New Collection…") { fontService.collectionPrompt = .create(families: []) }
                    Button("New Smart Collection…") { fontService.smartCollectionEditor = SmartCollectionEditorRequest() }
                } label: {
                    PhIcon(.plus, size: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Collection or Smart Collection")
                .accessibilityLabel("New Collection")
            }
            .padding(.leading, 6)

            // Active / Inactive / Missing Info only appear when they hold fonts (or are selected).
            let visibleStatuses = FontService.StatusFilter.allCases.filter { status in
                status == .all || fontService.count(for: status) > 0
                    || (fontService.activeCollectionID == nil && fontService.filterStatus == status)
            }
            ForEach(visibleStatuses, id: \.self) { status in
                LibraryRow(title: status == .all ? "All Fonts" : status.rawValue,
                           icon: Self.icon(for: status),
                           count: fontService.count(for: status),
                           isActive: fontService.activeCollectionID == nil && fontService.filterStatus == status) {
                    fontService.activeCollectionID = nil
                    fontService.filterStatus = status
                }
            }

            let userCollections = fontService.collections.filter(\.isSmart) + fontService.manualCollections
            if !userCollections.isEmpty {
                Divider().padding(.vertical, 4)
                if userCollections.count > maxVisibleRows {
                    ScrollView { rows(userCollections) }
                        .frame(height: CGFloat(maxVisibleRows) * (rowHeight + 2))
                } else {
                    rows(userCollections)
                }
            }
        }
    }

    private func rows(_ collections: [FontCollection]) -> some View {
        VStack(spacing: 2) {
            ForEach(collections) { collection in
                CollectionRow(collection: collection)
                    .frame(height: rowHeight)
            }
        }
    }

    private static func icon(for status: FontService.StatusFilter) -> Ph {
        switch status {
        case .all: return .textAa
        case .active: return .checkCircle
        case .inactive: return .xCircle
        case .missingInfo: return .warning
        }
    }
}

/// One sidebar library entry: icon, name, count.
private struct LibraryRow: View {
    let title: String
    let icon: Ph
    let count: Int
    let isActive: Bool
    var isDropTarget = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PhIcon(icon, size: 15)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isDropTarget ? 1.5 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct CollectionRow: View {
    @EnvironmentObject var fontService: FontService
    let collection: FontCollection
    @State private var isDropTarget = false

    var body: some View {
        let row = LibraryRow(title: collection.name, icon: collection.isSmart ? .funnel : .folderSimple,
                             count: fontService.count(in: collection),
                             isActive: fontService.activeCollectionID == collection.id,
                             isDropTarget: isDropTarget) {
            fontService.filterStatus = .all
            fontService.activeCollectionID = collection.id
        }
        .contextMenu {
            let members = fontService.fonts(in: collection)
            Button("Activate All") { fontService.setActive(true, for: members) }
                .disabled(!members.contains { $0.canToggleActivation && !$0.isActive })
            Button("Deactivate All") { fontService.setActive(false, for: members) }
                .disabled(!members.contains { $0.canToggleActivation && $0.isActive })
            Divider()
            if collection.isSmart {
                Button("Edit Smart Collection…") { fontService.smartCollectionEditor = SmartCollectionEditorRequest(collection: collection) }
            } else {
                Button("Rename…") { fontService.collectionPrompt = .rename(collection) }
            }
            Button("Delete Collection", role: .destructive) { fontService.deleteCollection(collection.id) }
        }

        // Only manual collections take dropped fonts (smart ones fill themselves).
        if collection.isSmart {
            row.help("Smart collection — fonts matching its rules are added automatically")
        } else {
            row.dropDestination(for: String.self) { families, _ in
                fontService.addFamilies(families, to: collection.id)
                return true
            } isTargeted: { isDropTarget = $0 }
        }
    }
}

/// "Add to Collection" submenu plus "Remove from <current>", for any font context menu
/// or toolbar menu. Lists manual collections only (smart ones fill themselves); those
/// already holding every font show a checkmark and remove on click.
struct CollectionMenuItems: View {
    @EnvironmentObject var fontService: FontService
    let fonts: [FontItem]

    var body: some View {
        Menu("Add to Collection") {
            ForEach(fontService.manualCollections) { collection in
                Button {
                    fontService.toggle(fonts, in: collection)
                } label: {
                    if fonts.allSatisfy({ collection.families.contains($0.familyName) }) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }
            if !fontService.manualCollections.isEmpty { Divider() }
            Button("New Collection…") {
                fontService.collectionPrompt = .create(families: fonts.map(\.familyName))
            }
        }
        if let active = fontService.activeCollection, !active.isSmart {
            Button("Remove from “\(active.name)”") {
                fontService.removeFamilies(fonts.map(\.familyName), from: active.id)
            }
        }
    }
}

/// Answers `FontService.collectionPrompt` with a name alert (new or rename).
struct CollectionNameAlert: ViewModifier {
    @EnvironmentObject var fontService: FontService
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(
                get: { fontService.collectionPrompt != nil },
                set: { if !$0 { fontService.collectionPrompt = nil } }
            )) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { fontService.collectionPrompt = nil }
                Button(confirmTitle) { commit() }
            }
            .onChange(of: fontService.collectionPrompt?.id) { _, _ in
                if case .rename(let collection) = fontService.collectionPrompt {
                    name = collection.name
                } else {
                    name = ""
                }
            }
    }

    private var title: String {
        if case .rename = fontService.collectionPrompt { return "Rename Collection" }
        return "New Collection"
    }

    private var confirmTitle: String {
        if case .rename = fontService.collectionPrompt { return "Rename" }
        return "Create"
    }

    private func commit() {
        switch fontService.collectionPrompt {
        case .create(let families):
            let collection = fontService.createCollection(named: name, families: families)
            // Starting an empty collection opens it; adding fonts to a new one stays put.
            if families.isEmpty { fontService.activeCollectionID = collection.id }
        case .rename(let collection):
            fontService.renameCollection(collection.id, to: name)
        case nil:
            break
        }
        fontService.collectionPrompt = nil
    }
}
