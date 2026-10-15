import SwiftUI
import CoreText

/// Fonts shipped inside the app for UI use (see Resources/Fonts, credited in
/// Acknowledgements). Loaded straight from the bundle file rather than registered with
/// macOS, so they never appear in the user's font library.
enum BundledFonts {
    // CTFontDescriptor is immutable and thread-safe; CoreText just lacks the Sendable annotation.
    nonisolated(unsafe) private static let pirataDescriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "PirataOne-Regular", withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        return descriptors.first
    }()

    /// Pirata One (SIL Open Font License) — the Blackletter label, since macOS has none.
    static func pirataOne(size: CGFloat) -> Font {
        guard let descriptor = pirataDescriptor else { return .system(size: size, weight: .heavy, design: .serif) }
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}
