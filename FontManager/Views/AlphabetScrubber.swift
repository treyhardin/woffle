import SwiftUI
import AppKit

/// Letter index for the sidebar's A–Z scrubber: which letters appear in the list, and the
/// first family under each, in the list's order (A–Z or Z–A).
struct AlphabetIndex {
    /// Bar letters top-to-bottom. "#" covers names starting with a digit or symbol, which
    /// sort ahead of letters — so it leads in A–Z and trails in Z–A, matching the list.
    let letters: [String]
    /// Letter → id of the first family under it.
    private let targets: [String: String]

    init(fonts: [FontItem], descending: Bool = false) {
        let ascending = ["#"] + (65...90).map { String(UnicodeScalar(UInt8($0))) }
        letters = descending ? ascending.reversed() : ascending
        var targets: [String: String] = [:]
        for font in fonts {
            let key = Self.letter(for: font.familyName)
            if targets[key] == nil { targets[key] = font.id }
        }
        self.targets = targets
    }

    func contains(_ letter: String) -> Bool { targets[letter] != nil }

    /// The family to jump to for a letter — the next letter down the bar that has fonts
    /// when this one has none, else the nearest one above.
    func target(for letter: String) -> String? {
        guard let start = letters.firstIndex(of: letter) else { return nil }
        let after = letters[start...].lazy.compactMap { targets[$0] }.first
        return after ?? letters[..<start].reversed().lazy.compactMap { targets[$0] }.first
    }

    /// "Émigré" → "E", "3M Sans" → "#".
    static func letter(for name: String) -> String {
        let folded = name.prefix(1).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let scalar = folded.unicodeScalars.first, ("A"..."Z").contains(Character(scalar)) else { return "#" }
        return folded
    }
}

/// A slim vertical A–Z bar. Click or drag along it to jump the list to a letter; letters
/// with no fonts are dimmed (and jump to the nearest one that has fonts). When the bar is
/// too short for every letter, it shows an evenly spaced subset — dragging still reaches all.
struct AlphabetScrubber: View {
    let index: AlphabetIndex
    let onSelect: (String) -> Void
    /// True while the pointer is over the bar or dragging it, so the parent keeps it shown.
    @Binding var isInteracting: Bool

    @State private var activeLetter: String?
    @State private var hovering = false
    private let rowHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let letters = index.letters
            let barHeight = min(geo.size.height, CGFloat(letters.count) * rowHeight)
            let step = max(1, Int((CGFloat(letters.count) * rowHeight / max(barHeight, 1)).rounded(.up)))
            let shown = letters.enumerated().filter { $0.offset % step == 0 }.map(\.element)

            VStack(spacing: 0) {
                ForEach(shown, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(for: letter))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 16, height: barHeight)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        // Map the pointer's height over the whole bar to a letter, so every
                        // letter is reachable even when only a subset is labeled.
                        let y = value.location.y - 4
                        let i = min(letters.count - 1, max(0, Int(y / barHeight * CGFloat(letters.count))))
                        let letter = letters[i]
                        isInteracting = true
                        guard letter != activeLetter else { return }
                        activeLetter = letter
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        onSelect(letter)
                    }
                    .onEnded { _ in
                        activeLetter = nil
                        isInteracting = hovering
                    }
            )
            .onHover { inside in
                hovering = inside
                isInteracting = inside || activeLetter != nil
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 16)
        .accessibilityHidden(true)  // A pointer convenience; the list itself stays navigable.
    }

    private func color(for letter: String) -> Color {
        if letter == activeLetter { return .accentColor }
        return index.contains(letter) ? .primary : Color.secondary.opacity(0.5)
    }
}

extension View {
    /// Adds the A–Z jump bar along this scrolling list's trailing edge. `fonts` must be in
    /// the list's on-screen order, with each row identified by `FontItem.id`.
    func alphabetScrubber(fonts: [FontItem], proxy: ScrollViewProxy, descending: Bool = false) -> some View {
        modifier(AlphabetScrubberOverlay(fonts: fonts, proxy: proxy, descending: descending))
    }
}

/// Shows the scrubber while the list scrolls (fading ~1s after it settles) and whenever the
/// pointer is near the trailing edge, so it's there when you reach for it.
private struct AlphabetScrubberOverlay: ViewModifier {
    let fonts: [FontItem]
    let proxy: ScrollViewProxy
    let descending: Bool

    @State private var recentlyScrolled = false
    @State private var pointerNearEdge = false
    @State private var interacting = false
    @State private var hideTask: Task<Void, Never>?
    @State private var width: CGFloat = 0

    /// Short lists don't need a scrubber.
    private static let minimumCount = 20
    /// How close to the trailing edge the pointer must be to reveal the bar.
    private static let edgeZone: CGFloat = 48

    private var isVisible: Bool { recentlyScrolled || pointerNearEdge || interacting }

    func body(content: Content) -> some View {
        content
            .background(ScrollWheelObserver { didScroll() })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onContinuousHover { phase in
                let near: Bool
                if case .active(let point) = phase { near = point.x > width - Self.edgeZone } else { near = false }
                if near != pointerNearEdge { pointerNearEdge = near }
            }
            .overlay(alignment: .trailing) {
                if fonts.count >= Self.minimumCount {
                    let index = AlphabetIndex(fonts: fonts, descending: descending)
                    AlphabetScrubber(index: index, onSelect: { letter in
                        if let id = index.target(for: letter) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }, isInteracting: $interacting)
                    .padding(.vertical, 10)
                    // Sits just left of the overlay scroll bar.
                    .padding(.trailing, 14)
                    .opacity(isVisible ? 1 : 0)
                    .offset(x: isVisible ? 0 : 6)
                    .allowsHitTesting(isVisible)
                    .animation(.easeOut(duration: 0.2), value: isVisible)
                }
            }
    }

    private func didScroll() {
        if !recentlyScrolled { recentlyScrolled = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            recentlyScrolled = false
        }
    }
}

/// Calls `onScroll` for scroll-wheel/trackpad events over this view (momentum included).
/// A local event monitor rather than a scroll-offset observer, so it works on macOS 14 and
/// never reaches into the List's internals. Transparent to clicks.
struct ScrollWheelObserver: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
    }

    final class ObserverView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onScroll?()
                    }
                }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
