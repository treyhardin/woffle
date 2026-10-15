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

/// The A–Z bar's visuals only. It never takes mouse events itself — a SwiftUI overlay that
/// does would swallow scroll-wheel input meant for the list underneath — so clicks and drags
/// are handled by `ScrubberEventMonitor` instead. When the bar is too short for every letter,
/// it labels an evenly spaced subset; dragging still reaches all of them.
struct AlphabetScrubber: View {
    let index: AlphabetIndex
    let barHeight: CGFloat
    let activeLetter: String?
    static let width: CGFloat = 16
    static let rowHeight: CGFloat = 14
    static let innerPadding: CGFloat = 4

    var body: some View {
        let letters = index.letters
        let step = max(1, Int((CGFloat(letters.count) * Self.rowHeight / max(barHeight, 1)).rounded(.up)))
        let shown = letters.enumerated().filter { $0.offset % step == 0 }.map(\.element)

        VStack(spacing: 0) {
            ForEach(shown, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color(for: letter))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.width, height: barHeight)
        .padding(.vertical, Self.innerPadding)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .allowsHitTesting(false)
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
    @State private var activeLetter: String?
    @State private var size: CGSize = .zero
    /// Held outside view state so rescheduling on every wheel tick doesn't redraw the list.
    @State private var hideTimer = HideTimer()

    /// Short lists don't need a scrubber.
    private static let minimumCount = 20
    /// How close to the trailing edge the pointer must be to reveal the bar.
    private static let edgeZone: CGFloat = 56

    private var isEnabled: Bool { fonts.count >= Self.minimumCount }
    private var isVisible: Bool { isEnabled && (recentlyScrolled || pointerNearEdge || activeLetter != nil) }

    /// Clear of the scroll bar: always-visible ("legacy") scroll bars, shown when a mouse is
    /// connected, take ~15pt at the edge; overlay scroll bars float over content.
    private var trailingInset: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 6
            : 14
    }

    private var barHeight: CGFloat {
        let letterCount = CGFloat(AlphabetIndex(fonts: [], descending: descending).letters.count)
        return max(0, min(size.height - 28, letterCount * AlphabetScrubber.rowHeight))
    }

    /// The bar's frame in this view's (top-left origin) coordinates.
    private var barRect: CGRect {
        let height = barHeight + AlphabetScrubber.innerPadding * 2
        return CGRect(x: size.width - trailingInset - AlphabetScrubber.width, y: (size.height - height) / 2,
                      width: AlphabetScrubber.width, height: height)
    }

    func body(content: Content) -> some View {
        let index = AlphabetIndex(fonts: isEnabled ? fonts : [], descending: descending)
        content
            .background(ScrubberEventMonitor(
                barRect: isVisible ? barRect : nil,
                onScroll: didScroll,
                onDrag: { point in
                    if let point { select(at: point, in: index) } else { activeLetter = nil }
                }
            ))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                let near: Bool
                if case .active(let point) = phase { near = point.x > size.width - Self.edgeZone } else { near = false }
                if near != pointerNearEdge { pointerNearEdge = near }
            }
            .overlay(alignment: .topLeading) {
                if isEnabled {
                    AlphabetScrubber(index: index, barHeight: barHeight, activeLetter: activeLetter)
                        .offset(x: barRect.minX + (isVisible ? 0 : 6), y: barRect.minY)
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: isVisible)
                }
            }
    }

    /// Maps the pointer's height over the whole bar to a letter, so every letter is
    /// reachable even when only a subset is labeled.
    private func select(at point: CGPoint, in index: AlphabetIndex) {
        let letters = index.letters
        guard !letters.isEmpty, barHeight > 0 else { return }
        let y = point.y - barRect.minY - AlphabetScrubber.innerPadding
        let i = min(letters.count - 1, max(0, Int(y / barHeight * CGFloat(letters.count))))
        let letter = letters[i]
        guard letter != activeLetter else { return }
        activeLetter = letter
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if let id = index.target(for: letter) { proxy.scrollTo(id, anchor: .top) }
    }

    private func didScroll() {
        if !recentlyScrolled { recentlyScrolled = true }
        hideTimer.schedule(after: 1.2) { recentlyScrolled = false }
    }
}

/// Debounced hide timer kept in a reference so rescheduling doesn't invalidate the view.
@MainActor
private final class HideTimer {
    private var task: Task<Void, Never>?

    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

/// Watches events over the list via a local event monitor (works on macOS 14 and never reaches
/// into the List's internals):
/// - scroll-wheel/trackpad scrolls → `onScroll` (events always continue to the list);
/// - clicks and drags that start on the visible bar → `onDrag(point)`, then `onDrag(nil)` on
///   release. Those are consumed so they don't also select a row underneath.
/// The view itself is transparent to clicks.
private struct ScrubberEventMonitor: NSViewRepresentable {
    /// The bar's frame (top-left origin) while it's visible; nil when hidden.
    let barRect: CGRect?
    let onScroll: () -> Void
    let onDrag: (CGPoint?) -> Void

    func makeNSView(context: Context) -> MonitorView { update(MonitorView()) }
    func updateNSView(_ view: MonitorView, context: Context) { _ = update(view) }

    private func update(_ view: MonitorView) -> MonitorView {
        view.barRect = barRect
        view.onScroll = onScroll
        view.onDrag = onDrag
        return view
    }

    final class MonitorView: NSView {
        var barRect: CGRect?
        var onScroll: (() -> Void)?
        var onDrag: ((CGPoint?) -> Void)?
        private var monitor: Any?
        private var dragging = false

        // Match SwiftUI's top-left origin so `barRect` needs no conversion.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                // NSEvent isn't Sendable, so decide inside and pass the event through outside.
                let consume = MainActor.assumeIsolated { self?.shouldConsume(event) ?? false }
                return consume ? nil : event
            }
        }

        private func shouldConsume(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .scrollWheel:
                if bounds.contains(point) { onScroll?() }
                return false
            case .leftMouseDown:
                guard let barRect, barRect.insetBy(dx: -4, dy: 0).contains(point) else { return false }
                dragging = true
                onDrag?(point)
                return true
            case .leftMouseDragged where dragging:
                onDrag?(point)
                return true
            case .leftMouseUp where dragging:
                dragging = false
                onDrag?(nil)
                return true
            default:
                return false
            }
        }
    }
}
