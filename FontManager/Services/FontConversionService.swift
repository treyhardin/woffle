import Foundation
import CoreText

/// Member-aware bridge over `FontConversionEngine`: resolves a `FontMember` to its
/// font data and exports it to a chosen format.
enum FontConversionService {

    /// Build a CTFont for a specific member, preferring the on-disk face so that
    /// inactive custom fonts and individual faces of a .ttc resolve correctly.
    /// Returns nil if no font with the exact PostScript name can be resolved — important
    /// because the name-based fallback would otherwise silently substitute a different font.
    static func ctFont(for member: FontMember) -> CTFont? {
        if let url = member.fileURL,
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
            for descriptor in descriptors {
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                   name == member.postScriptName {
                    return CTFontCreateWithFontDescriptor(descriptor, 0, nil)
                }
            }
        }
        // Name-based fallback (for active fonts with no usable fileURL): verify CoreText
        // returned the font we actually asked for rather than a substitute.
        let descriptor = CTFontDescriptorCreateWithNameAndSize(member.postScriptName as CFString, 0)
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        let resolved = CTFontCopyPostScriptName(font) as String
        return resolved == member.postScriptName ? font : nil
    }

    /// The source SFNT for a member: byte-exact copy when it's already a single-face
    /// OTF/TTF file, otherwise a single face assembled from CoreText tables (handles
    /// .ttc/.dfont collections and system fonts).
    static func sourceSFNT(for member: FontMember) throws -> Data {
        if let url = member.fileURL,
           ["otf", "ttf"].contains(url.pathExtension.lowercased()),
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           descriptors.count == 1,
           let data = try? Data(contentsOf: url) {
            return data
        }
        guard let font = ctFont(for: member) else { throw FontConversionError.cannotCreateFont }
        return try FontConversionEngine.assembleSFNT(from: font)
    }

    /// Export a member to a given format, returning the bytes and the file extension.
    static func export(_ member: FontMember, as format: ExportFormat) throws -> (data: Data, ext: String) {
        guard member.isExportable else { throw FontConversionError.protectedSystemFont }
        let sfnt = try sourceSFNT(for: member)
        switch format {
        case .native:
            return (sfnt, FontConversionEngine.isTrueType(sfnt) ? "ttf" : "otf")
        case .woff:
            return (try FontConversionEngine.wrapWOFF(sfnt: sfnt), "woff")
        case .woff2:
            return (try WOFF2.encode(sfnt), "woff2")
        }
    }

    /// Decode any web/desktop font file into an installable SFNT, including WOFF2.
    static func webFontToSFNT(_ url: URL) throws -> (data: Data, isTrueType: Bool) {
        guard !FontMember.isAppleSupplied(url) else { throw FontConversionError.protectedSystemFont }
        let data = try Data(contentsOf: url)
        if data.count >= 4, Array(data.prefix(4)) == Array("wOF2".utf8) {
            let sfnt = try WOFF2.decode(data)
            return (sfnt, FontConversionEngine.isTrueType(sfnt))
        }
        return try FontConversionEngine.webFontToSFNT(url)
    }

    /// Convert any font file (WOFF/WOFF2/OTF/TTF) to a target format — in either direction.
    static func convert(_ url: URL, to format: ExportFormat) throws -> (data: Data, ext: String) {
        let decoded = try webFontToSFNT(url)
        switch format {
        case .native:
            return (decoded.data, decoded.isTrueType ? "ttf" : "otf")
        case .woff:
            return (try FontConversionEngine.wrapWOFF(sfnt: decoded.data), "woff")
        case .woff2:
            return (try WOFF2.encode(decoded.data), "woff2")
        }
    }

    // MARK: - Upload → detect → download flow

    /// A font file the user uploaded, decoded once so any target format is instant.
    struct UploadedFont: Sendable {
        let url: URL
        let sfnt: Data
        let isTrueType: Bool

        var displayName: String { url.lastPathComponent }
        var sourceExtension: String { url.pathExtension.lowercased() }
        var outlineDescription: String { isTrueType ? "TrueType outlines" : "PostScript (CFF) outlines" }
    }

    /// A format the uploaded font can be converted into.
    struct ConvertTarget: Identifiable, Sendable {
        let format: ExportFormat
        let ext: String
        var id: String { ext }
        var label: String { ext.uppercased() }
    }

    static func upload(_ url: URL) throws -> UploadedFont {
        let decoded = try webFontToSFNT(url)
        return UploadedFont(url: url, sfnt: decoded.data, isTrueType: decoded.isTrueType)
    }

    /// Formats the upload can be converted to, excluding the format it's already in.
    /// (The desktop option matches the source's outline type — we don't redraw outlines,
    /// so a CFF font offers OTF and a TrueType font offers TTF, not both.)
    static func availableTargets(for uploaded: UploadedFont) -> [ConvertTarget] {
        let desktopExt = uploaded.isTrueType ? "ttf" : "otf"
        let all = [
            ConvertTarget(format: .native, ext: desktopExt),
            ConvertTarget(format: .woff, ext: "woff"),
            ConvertTarget(format: .woff2, ext: "woff2"),
        ]
        return all.filter { $0.ext != uploaded.sourceExtension }
    }

    static func encode(_ uploaded: UploadedFont, to format: ExportFormat) throws -> (data: Data, ext: String) {
        switch format {
        case .native:
            return (uploaded.sfnt, uploaded.isTrueType ? "ttf" : "otf")
        case .woff:
            return (try FontConversionEngine.wrapWOFF(sfnt: uploaded.sfnt), "woff")
        case .woff2:
            return (try WOFF2.encode(uploaded.sfnt), "woff2")
        }
    }

    /// A clean default filename (without extension) for a member, never empty.
    static func baseFilename(for member: FontMember) -> String {
        let candidates = [member.postScriptName, member.displayName, member.styleName]
        let name = candidates.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Font"
        return name.replacingOccurrences(of: "/", with: "-")
    }

    /// The desktop extension (otf/ttf) a member would export to, determined cheaply.
    static func nativeExtension(for member: FontMember) -> String {
        if let ext = member.fileURL?.pathExtension.lowercased(), ext == "otf" || ext == "ttf" {
            return ext
        }
        if let font = ctFont(for: member) {
            let glyf = CTFontTableTag(0x676C_7966) // 'glyf'
            if CTFontCopyTable(font, glyf, CTFontTableOptions(rawValue: 0)) != nil { return "ttf" }
        }
        return "otf"
    }

    /// Default filename (with extension) for exporting a member to a format.
    static func suggestedFilename(for member: FontMember, format: ExportFormat) -> String {
        let ext: String
        switch format {
        case .native: ext = nativeExtension(for: member)
        case .woff: ext = "woff"
        case .woff2: ext = "woff2"
        }
        return "\(baseFilename(for: member)).\(ext)"
    }
}
