import SwiftUI

/// The persistent font list shown between the filters sidebar and the detail view once a
/// font is open: every font matching the current filters, in the browse order, with the
/// open font selected — so you can step through fonts (click, or ↑/↓) without going back.
struct FontListColumn: View {
    @EnvironmentObject var fontService: FontService

    var body: some View {
        let fonts = fontService.browseFonts
        VStack(spacing: 0) {
            // Sticky way back to the landing grid (also ⌘[).
            BackToGridButton()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            Divider()

            if fonts.isEmpty {
                Text("No fonts match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(fonts, selection: $fontService.selection) { font in
                        FontRowView(font: font)
                    }
                    .listStyle(.inset)
                    .alphabetScrubber(fonts: fontService.sortOrder == .mostRecent ? [] : fonts,
                                      proxy: proxy,
                                      descending: fontService.sortOrder == .nameDescending)
                    // Land with the open font in view.
                    .onAppear {
                        if let id = fontService.selection.first { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            Divider()
            Text("\(fonts.count) families")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
        }
    }
}
