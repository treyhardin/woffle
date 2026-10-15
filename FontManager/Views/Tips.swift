import SwiftUI
import TipKit

/// One-time contextual tips (TipKit). Each shows once; TipKit remembers dismissals.
enum AppTips {
    /// Donated whenever a font's detail view opens, to pace tips after real use.
    static let fontOpened = Tips.Event(id: "fontOpened")

    static func configure() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

/// Shown in the sidebar once someone has opened a font: the actions that aren't visible.
struct SidebarActionsTip: Tip {
    var title: Text { Text("Quick actions") }
    var message: Text? {
        Text("Right-click a font to activate it or show it in Finder. Hover the right edge of a list to jump by letter.")
    }
    var image: Image? { Ph.list.image }

    var rules: [Rule] {
        #Rule(AppTips.fontOpened) { $0.donations.count >= 1 }
    }
}

/// Popover on the detail view's Edit button, after a couple of fonts have been opened.
struct EditDetailsTip: Tip {
    var title: Text { Text("Fix a font's details") }
    var message: Text? {
        Text("Wrong style, or a missing foundry? Click Edit to correct it. Your font files are never changed.")
    }
    var image: Image? { Ph.pencilSimple.image }

    var rules: [Rule] {
        #Rule(AppTips.fontOpened) { $0.donations.count >= 2 }
    }
}
