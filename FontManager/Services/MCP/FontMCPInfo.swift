import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP

/// Read-only detail tools: `get_font_info` (full metadata incl. licensing), `compare_fonts`
/// (side-by-side specimen image) and `convert_font` (stateless format conversion of bytes
/// the client supplies). Pure functions over the catalog snapshot — safe off the main actor.
enum FontMCPInfo {

    // MARK: - get_font_info

    struct LicenseInfo: Codable {
        let copyright: String?
        let trademark: String?
        let license: String?
        let licenseURL: String?
        let manufacturer: String?
        let vendorURL: String?
        let designer: String?
        let designerURL: String?
        let version: String?
        let description: String?
        /// Decoded OS/2 fsType: how the font may be embedded in documents/apps.
        let embedding: String?
    }

    struct FaceInfo: Codable {
        let postScriptName, style: String
        let weight: Int
        let sourceFormat: String
        let exportable: Bool
        let file: String?
    }

    struct FamilyInfo: Codable {
        let family, foundry, classification, width, source: String
        let detected: DetectedAttributes
        let overridden: [String]
        let collections: [String]
        let active: Bool
        let canToggleActivation: Bool
        let license: LicenseInfo?
        let faces: [FaceInfo]
    }

    static func getFontInfo(_ records: [FontRecord], _ args: [String: Value]) -> CallTool.Result {
        let names = FontMCPTools.stringArray(args["families"])
        guard !names.isEmpty else { return FontMCPTools.errorResult("`families` is required: an array of family names (from find_fonts).") }
        guard names.count <= 50 else { return FontMCPTools.errorResult("At most 50 families per call.") }

        var found: [FamilyInfo] = []
        var missing: [String] = []
        for name in names {
            guard let record = records.first(where: { $0.family.caseInsensitiveCompare(name) == .orderedSame }) else {
                missing.append(name)
                continue
            }
            found.append(FamilyInfo(
                family: record.family,
                foundry: record.foundry,
                classification: record.classification,
                width: record.width,
                source: record.source,
                detected: record.detected,
                overridden: record.overridden,
                collections: record.collections,
                active: record.active,
                canToggleActivation: record.canToggleActivation,
                license: FontMCPTools.representativeMember(record).flatMap(license(for:)),
                faces: zip(record.faces, record.members).map { face, member in
                    FaceInfo(postScriptName: face.postScriptName, style: face.style, weight: face.weight,
                             sourceFormat: face.sourceFormat, exportable: face.exportable,
                             file: member.fileURL?.path)
                }
            ))
        }

        struct Result: Codable { let families: [FamilyInfo]; let notFound: [String] }
        var summary = "Details for \(found.count) family(ies)."
        if !missing.isEmpty { summary += " Not found: \(missing.joined(separator: ", ")) — use find_fonts to look names up." }
        return FontMCPTools.encoded(Result(families: found, notFound: missing), summary: summary)
    }

    /// Name-table strings plus embedding permissions for one face.
    static func license(for member: FontMember) -> LicenseInfo? {
        guard let font = FontConversionService.ctFont(for: member) else { return nil }
        func name(_ key: CFString) -> String? {
            (CTFontCopyName(font, key) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return LicenseInfo(
            copyright: name(kCTFontCopyrightNameKey),
            trademark: name(kCTFontTrademarkNameKey),
            license: name(kCTFontLicenseNameKey),
            licenseURL: name(kCTFontLicenseURLNameKey),
            manufacturer: name(kCTFontManufacturerNameKey),
            vendorURL: name(kCTFontVendorURLNameKey),
            designer: name(kCTFontDesignerNameKey),
            designerURL: name(kCTFontDesignerURLNameKey),
            version: name(kCTFontVersionNameKey),
            description: name(kCTFontDescriptionNameKey),
            embedding: embedding(for: font)
        )
    }

    /// Decodes the OS/2 `fsType` field (offset 8), which states embedding permissions.
    private static func embedding(for font: CTFont) -> String? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 10 else { return nil }
        let fsType = UInt16(table[8]) << 8 | UInt16(table[9])
        var parts: [String]
        switch fsType & 0x000F {
        case 0: parts = ["Installable (no embedding restrictions)"]
        case let bits where bits & 0x0002 != 0 && bits & 0x000C == 0: parts = ["Restricted — may not be embedded without the foundry's permission"]
        case let bits where bits & 0x0008 != 0: parts = ["Editable embedding allowed"]
        case let bits where bits & 0x0004 != 0: parts = ["Preview & print embedding only"]
        default: parts = ["Unknown (fsType \(fsType))"]
        }
        if fsType & 0x0100 != 0 { parts.append("no subsetting") }
        if fsType & 0x0200 != 0 { parts.append("bitmap embedding only") }
        return parts.joined(separator: "; ")
    }

    // MARK: - compare_fonts

    static func compareFonts(_ records: [FontRecord], _ args: [String: Value]) -> CallTool.Result {
        let text = args["text"]?.stringValue ?? "Sphinx of black quartz, judge my vow"
        let size = CGFloat(min(max(args["pointSize"]?.intValue ?? 36, 12), 96))

        var entries: [(label: String, member: FontMember)] = []
        var missing: [String] = []
        for name in FontMCPTools.stringArray(args["families"]) {
            if let record = records.first(where: { $0.family.caseInsensitiveCompare(name) == .orderedSame }),
               let member = FontMCPTools.representativeMember(record) {
                entries.append((record.family, member))
            } else { missing.append(name) }
        }
        let byFace = Dictionary(records.flatMap { r in r.members.map { ($0.postScriptName, (r.family, $0)) } }, uniquingKeysWith: { a, _ in a })
        for ps in FontMCPTools.stringArray(args["faces"]) {
            if let (family, member) = byFace[ps] { entries.append(("\(family) — \(member.styleName)", member)) } else { missing.append(ps) }
        }
        guard !entries.isEmpty else { return FontMCPTools.errorResult("Pass `families` (names) and/or `faces` (PostScript names) to compare.") }
        guard entries.count <= 12 else { return FontMCPTools.errorResult("Compare at most 12 fonts at a time.") }
        guard let png = SpecimenRenderer.comparisonPNGBase64(entries, text: text, pointSize: size) else {
            return FontMCPTools.errorResult("Couldn't render those fonts.")
        }
        var summary = "Comparison of \(entries.count) font(s): \(entries.map(\.label).joined(separator: ", "))."
        if !missing.isEmpty { summary += " Not found: \(missing.joined(separator: ", "))." }
        return CallTool.Result(content: [.text(summary), .image(png, "image/png")])
    }

    // MARK: - convert_font

    /// Converts font bytes the client supplies (any of WOFF/WOFF2/OTF/TTF) to another format.
    /// Nothing is added to the library.
    static func convertFont(_ args: [String: Value]) -> CallTool.Result {
        guard let base64 = args["dataBase64"]?.stringValue, let data = Data(base64Encoded: base64) else {
            return FontMCPTools.errorResult("`dataBase64` is required: the font file's bytes, base64-encoded.")
        }
        let target: ExportFormat
        switch args["format"]?.stringValue?.lowercased() ?? "woff2" {
        case "woff2": target = .woff2
        case "woff": target = .woff
        case "otf", "ttf", "native": target = .native
        case let other: return FontMCPTools.errorResult("Unknown format '\(other)'. Use woff2, woff, otf, or ttf.")
        }
        let name = (args["filename"]?.stringValue).map { ($0 as NSString).lastPathComponent } ?? "font"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try data.write(to: temp)
            let uploaded = try FontConversionService.upload(temp)
            let (output, ext) = try FontConversionService.encode(uploaded, to: target)
            let base = (name as NSString).deletingPathExtension
            struct Result: Codable { let filename: String; let format: String; let sizeBytes: Int; let bytesBase64: String }
            return FontMCPTools.encoded(
                Result(filename: "\(base).\(ext)", format: ext, sizeBytes: output.count, bytesBase64: output.base64EncodedString()),
                summary: "Converted \(name) to \(ext.uppercased()) (\(output.count) bytes, base64 in structuredContent)."
            )
        } catch {
            return FontMCPTools.errorResult(error.localizedDescription)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension SpecimenRenderer {
    /// Stacks one labeled specimen row per entry into a single PNG, so fonts can be judged
    /// side by side. CoreGraphics/CoreText only — safe off the main actor.
    static func comparisonPNGBase64(_ entries: [(label: String, member: FontMember)], text: String, pointSize: CGFloat, maxWidth: CGFloat = 1200) -> String? {
        let labelFont = CTFontCreateUIFontForLanguage(.system, 13, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        func line(_ string: String, font: CTFont, gray: CGFloat) -> CTLine? {
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1)]
            guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return nil }
            return CTLineCreateWithAttributedString(attributed)
        }
        func metrics(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            return (width, ascent, descent)
        }

        struct Row { let label: CTLine; let specimen: CTLine }
        let rows: [Row] = entries.compactMap { entry in
            guard let font = FontConversionService.ctFont(for: entry.member),
                  let label = line(entry.label, font: labelFont, gray: 0.45),
                  let specimen = line(text, font: CTFontCreateCopyWithAttributes(font, pointSize, nil, nil), gray: 0.08) else { return nil }
            return Row(label: label, specimen: specimen)
        }
        guard !rows.isEmpty else { return nil }

        let padding: CGFloat = 24, gap: CGFloat = 6, rowSpacing: CGFloat = 22
        let contentWidth = rows.map { max(metrics($0.label).width, metrics($0.specimen).width) }.max() ?? 0
        let width = min(maxWidth, ceil(contentWidth + padding * 2))
        let rowHeights = rows.map { row -> CGFloat in
            let l = metrics(row.label), s = metrics(row.specimen)
            return l.ascent + l.descent + gap + s.ascent + s.descent
        }
        let height = ceil(rowHeights.reduce(0, +) + rowSpacing * CGFloat(rows.count - 1) + padding * 2)

        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics' origin is bottom-left; lay rows out top-down.
        var top = height - padding
        for row in rows {
            let l = metrics(row.label), s = metrics(row.specimen)
            context.textPosition = CGPoint(x: padding, y: top - l.ascent)
            CTLineDraw(row.label, context)
            top -= l.ascent + l.descent + gap
            context.textPosition = CGPoint(x: padding, y: top - s.ascent)
            CTLineDraw(row.specimen, context)
            top -= s.ascent + s.descent + rowSpacing
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
