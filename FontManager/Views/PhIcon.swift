import SwiftUI

/// Vendored [Phosphor](https://phosphoricons.com) icons (regular weight), rendered as
/// template images from the asset catalog. Only the glyphs the app actually uses are
/// bundled (`Assets.xcassets/ph-*`). Unlike SF Symbols, Phosphor glyphs don't auto-size
/// to the surrounding font, so `PhIcon` takes an explicit point size; tint them with
/// `.foregroundStyle` like any template image.
enum Ph: String {
    case arrowsClockwise = "ph-arrows-clockwise"
    case folderPlus = "ph-folder-plus"
    case fileArrowDown = "ph-file-arrow-down"
    case fileArrowUp = "ph-file-arrow-up"
    case fileText = "ph-file-text"
    case magnifyingGlass = "ph-magnifying-glass"
    case xCircle = "ph-x-circle"
    case caretUpDown = "ph-caret-up-down"
    case caretLeft = "ph-caret-left"
    case pencilSimple = "ph-pencil-simple"
    case downloadSimple = "ph-download-simple"
    case folder = "ph-folder"
    case arrowCounterClockwise = "ph-arrow-counter-clockwise"
    case arrowCircleDown = "ph-arrow-circle-down"
    case textAa = "ph-text-aa"
    case funnel = "ph-funnel"
    case plus = "ph-plus"
    case trash = "ph-trash"
    case warning = "ph-warning"
    case checkCircle = "ph-check-circle"
    case list = "ph-list"
    case squaresFour = "ph-squares-four"
    case sparkle = "ph-sparkle"
    case folderSimple = "ph-folder-simple"
    case folderSimplePlus = "ph-folder-simple-plus"
    case caretDown = "ph-caret-down"
    case square = "ph-square"
    case checkSquare = "ph-check-square"

    var image: Image { Image(rawValue).renderingMode(.template) }
}

/// A square Phosphor icon at a fixed point size. Tint via `.foregroundStyle`.
struct PhIcon: View {
    private let icon: Ph
    private let size: CGFloat

    init(_ icon: Ph, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        icon.image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// A `Label` whose icon is a Phosphor glyph, so `.labelStyle`, buttons, and toolbars
/// treat it like any other `Label`.
struct PhLabel: View {
    private let title: String
    private let icon: Ph
    private let size: CGFloat

    init(_ title: String, icon: Ph, size: CGFloat = 16) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            PhIcon(icon, size: size)
        }
    }
}
