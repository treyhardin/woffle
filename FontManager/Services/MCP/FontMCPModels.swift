import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - CSS weight

/// Maps a face's style name to a CSS numeric weight (100–900). `FontMember.weight` is an
/// internal CoreText/AppKit scale (~0–14), not CSS weight — the style name is both the
/// reliable signal and what web authors expect in `@font-face`.
enum CSSWeight {
    static func fromStyle(_ style: String) -> Int {
        let s = style.lowercased()
        // Check compound names before their substrings (extrabold before bold, etc.).
        if s.contains("thin") || s.contains("hairline") { return 100 }
        if s.contains("extralight") || s.contains("ultralight") { return 200 }
        if s.contains("semibold") || s.contains("demibold") { return 600 }
        if s.contains("extrabold") || s.contains("ultrabold") { return 800 }
        if s.contains("black") || s.contains("heavy") { return 900 }
        if s.contains("medium") { return 500 }
        if s.contains("light") { return 300 }
        if s.contains("bold") { return 700 }
        return 400
    }
}

// MARK: - Snapshot DTOs

/// A single face within a family, as surfaced to MCP clients.
struct FontFace: Sendable, Codable {
    let postScriptName: String
    let style: String
    /// CSS numeric weight (100–900), derived from the style name.
    let weight: Int
    /// The face's on-disk container (`otf`/`ttf`/`woff`/`woff2`/`ttc`) or `system` when
    /// there's no backing file. Exportable faces can be delivered as woff2/woff/otf/ttf.
    let sourceFormat: String
    /// False for Apple's bundled system fonts, which `get_font` won't deliver (licensing).
    let exportable: Bool
}

/// A family record: display metadata (override-aware) plus the underlying members needed
/// for conversion. `members` is excluded from JSON output (it carries file URLs) — the
/// `faces` projection is what clients see.
struct FontRecord: Sendable {
    let family: String
    let foundry: String
    let classification: String
    let width: String
    let source: String
    let active: Bool
    let dateAdded: Date?
    let faces: [FontFace]
    let members: [FontMember]
}

/// Builds a Sendable snapshot of the whole catalog on the main actor, resolving user
/// overrides (classification/width/foundry) exactly as the UI shows them.
enum FontCatalog {
    @MainActor
    static func snapshot(_ service: FontService) -> [FontRecord] {
        service.fonts.map { item in
            FontRecord(
                family: item.familyName,
                foundry: service.displayFoundry(item),
                classification: service.effectiveClassification(item).rawValue,
                width: service.effectiveWidth(item).rawValue,
                source: sourceLabel(item.source),
                active: item.isActive,
                dateAdded: item.dateAdded,
                faces: item.members.map { member in
                    FontFace(
                        postScriptName: member.postScriptName,
                        style: member.styleName,
                        weight: CSSWeight.fromStyle(member.styleName),
                        sourceFormat: sourceFormat(member),
                        exportable: member.isExportable
                    )
                },
                members: item.members
            )
        }
    }

    /// Snapshot the catalog, briefly waiting if it hasn't loaded yet. On macOS the library
    /// is never genuinely empty (system fonts always exist), so an empty snapshot means
    /// enumeration is still in flight — common if a client connects right at app launch.
    /// Polls up to `attempts × interval` (default ~4s) so that first call gets real data
    /// instead of an empty result; returns whatever it has (possibly empty) if it times out.
    static func snapshotWhenReady(_ service: FontService, attempts: Int = 20, intervalNanos: UInt64 = 200_000_000) async -> [FontRecord] {
        for _ in 0..<attempts {
            let records = await snapshot(service)
            if !records.isEmpty { return records }
            try? await Task.sleep(nanoseconds: intervalNanos)
        }
        return await snapshot(service)
    }

    static func sourceLabel(_ source: FontSource) -> String {
        switch source {
        case .system: return "system"
        case .custom: return "custom"
        case .imported: return "imported"
        }
    }

    static func sourceFormat(_ member: FontMember) -> String {
        guard let ext = member.fileURL?.pathExtension.lowercased(), !ext.isEmpty else { return "system" }
        return ext
    }
}

// MARK: - @font-face generation

enum FontFaceCSS {
    /// A ready-to-paste `@font-face` rule for a delivered file.
    static func rule(family: String, weight: Int, style: String, ext: String, filename: String, pathPrefix: String, display: String) -> String {
        let italic = style.lowercased().contains("italic") || style.lowercased().contains("oblique")
        let formatToken: String
        switch ext.lowercased() {
        case "woff2": formatToken = "woff2"
        case "woff": formatToken = "woff"
        case "ttf": formatToken = "truetype"
        default: formatToken = "opentype"
        }
        let url = pathPrefix + filename
        return """
        @font-face {
          font-family: "\(family)";
          font-style: \(italic ? "italic" : "normal");
          font-weight: \(weight);
          font-display: \(display);
          src: url("\(url)") format("\(formatToken)");
        }
        """
    }
}

// MARK: - Specimen rendering

/// Renders a small PNG specimen of a face so vision-capable agents can *see* the type.
/// Uses CoreGraphics + CoreText directly, so it's safe to call off the main actor.
enum SpecimenRenderer {
    static func pngBase64(for member: FontMember, text: String, pointSize: CGFloat = 40, maxWidth: CGFloat = 640) -> String? {
        guard let ctFont = FontConversionService.ctFont(for: member) else { return nil }
        let sized = CTFontCreateCopyWithAttributes(ctFont, pointSize, nil, nil)

        // Use CoreText's native attribute keys (CFString) so this needs no AppKit and
        // stays safe to call off the main actor.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: sized,
            kCTForegroundColorAttributeName: CGColor(gray: 0.08, alpha: 1),
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padding: CGFloat = pointSize * 0.4
        let width = min(maxWidth, ceil(textWidth + padding * 2))
        let height = ceil(ascent + descent + padding * 2)
        guard width > 1, height > 1 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: padding, y: descent + padding)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
