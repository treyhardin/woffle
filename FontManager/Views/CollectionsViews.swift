import SwiftUI

/// Sidebar collections, just above the font list: the built-in "All Fonts" (always first,
/// selected by default, can't be deleted) followed by the user's own. Picking one scopes both
/// the sidebar list and the browse grid. Fonts can be dragged onto a collection to add them.
struct SidebarLibrarySection: View {
    @EnvironmentObject var fontService: FontService
    /// Past this many collections the list scrolls rather than pushing the filters down.
    private let maxVisibleRows = 6
    private let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("COLLECTIONS")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    fontService.collectionPrompt = .create(families: [])
                } label: {
                    PhIcon(.plus, size: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Collection")
                .accessibilityLabel("New Collection")
            }
            .padding(.leading, 6)

            LibraryRow(title: "All Fonts", icon: .textAa, count: fontService.fonts.count,
                       isActive: fontService.activeCollectionID == nil) {
                fontService.activeCollectionID = nil
            }

            if fontService.collections.count > maxVisibleRows {
                ScrollView { collectionRows }
                    .frame(height: CGFloat(maxVisibleRows) * (rowHeight + 2))
            } else {
                collectionRows
            }
        }
    }

    private var collectionRows: some View {
        VStack(spacing: 2) {
            ForEach(fontService.collections) { collection in
                CollectionRow(collection: collection)
                    .frame(height: rowHeight)
            }
        }
    }
}

/// One sidebar library entry (All Fonts or a collection): icon, name, count.
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
        LibraryRow(title: collection.name, icon: .folderSimple,
                   count: fontService.count(in: collection),
                   isActive: fontService.activeCollectionID == collection.id,
                   isDropTarget: isDropTarget) {
            fontService.activeCollectionID = collection.id
        }
        // Font rows and cards drag their family name.
        .dropDestination(for: String.self) { families, _ in
            fontService.addFamilies(families, to: collection.id)
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            let members = fontService.fonts(in: collection)
            Button("Activate All") { fontService.setActive(true, for: members) }
                .disabled(!members.contains { $0.canToggleActivation && !$0.isActive })
            Button("Deactivate All") { fontService.setActive(false, for: members) }
                .disabled(!members.contains { $0.canToggleActivation && $0.isActive })
            Divider()
            Button("Rename…") { fontService.collectionPrompt = .rename(collection) }
            Button("Delete Collection", role: .destructive) { fontService.deleteCollection(collection.id) }
        }
    }
}

/// "Add to Collection" submenu plus "Remove from <current>", for any font context menu
/// or toolbar menu. Collections already holding every font show a checkmark and remove
/// on click.
struct CollectionMenuItems: View {
    @EnvironmentObject var fontService: FontService
    let fonts: [FontItem]

    var body: some View {
        Menu("Add to Collection") {
            ForEach(fontService.collections) { collection in
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
            if !fontService.collections.isEmpty { Divider() }
            Button("New Collection…") {
                fontService.collectionPrompt = .create(families: fonts.map(\.familyName))
            }
        }
        if let active = fontService.activeCollection {
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
