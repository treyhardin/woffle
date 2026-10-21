import Foundation
import MCP

/// Pure tool implementations. Each takes a Sendable catalog snapshot (built on the main
/// actor by the caller) plus the client's arguments, and returns a `CallTool.Result`.
/// No app/UI state is touched here, so these are safe to run off the main actor.
enum FontMCPTools {

    // MARK: - list_attributes

    static func listAttributes(_ records: [FontRecord]) -> CallTool.Result {
        struct FoundryCount: Codable { let name: String; let count: Int }
        struct AttributesResult: Codable {
            let totalFamilies: Int
            let classifications: [String]
            let widths: [String]
            let sources: [String]
            let foundries: [FoundryCount]
            let collections: [FoundryCount]
            let weightRange: [Int]
        }

        var foundryCounts: [String: Int] = [:]
        var collectionCounts: [String: Int] = [:]
        var classifications: Set<String> = []
        var widths: Set<String> = []
        var sources: Set<String> = []
        var minWeight = Int.max, maxWeight = Int.min

        for record in records {
            foundryCounts[record.foundry, default: 0] += 1
            classifications.insert(record.classification)
            widths.insert(record.width)
            sources.insert(record.source)
            for collection in record.collections { collectionCounts[collection, default: 0] += 1 }
            for face in record.faces {
                minWeight = min(minWeight, face.weight)
                maxWeight = max(maxWeight, face.weight)
            }
        }

        let foundries = foundryCounts
            .map { FoundryCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let result = AttributesResult(
            totalFamilies: records.count,
            classifications: classifications.sorted(),
            widths: widths.sorted(),
            sources: sources.sorted(),
            foundries: foundries,
            collections: collectionCounts
                .map { FoundryCount(name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            weightRange: records.isEmpty ? [] : [minWeight, maxWeight]
        )
        return encoded(result, summary: "\(records.count) families available.")
    }

    // MARK: - find_fonts

    static func findFonts(_ records: [FontRecord], _ args: [String: Value]) -> CallTool.Result {
        let name = args["name"]?.stringValue?.lowercased()
        let classifications = Set(stringArray(args["classification"]).map { $0.lowercased() })
        let widths = Set(stringArray(args["width"]).map { $0.lowercased() })
        let sources = Set(stringArray(args["source"]).map { $0.lowercased() })
        let collections = Set(stringArray(args["collection"]).map { $0.lowercased() })
        let weightMin = args["weightMin"]?.intValue
        let weightMax = args["weightMax"]?.intValue
        let includeSpecimen = args["includeSpecimen"]?.boolValue ?? false
        let specimenText = args["specimenText"]?.stringValue ?? "Sphinx of black quartz"
        let limit = min(max(args["limit"]?.intValue ?? 50, 1), 200)
        let offset = max(args["offset"]?.intValue ?? 0, 0)

        // Attribute filters first (everything except the free-text name search).
        let attrFiltered = records.filter { record in
            if !classifications.isEmpty, !classifications.contains(record.classification.lowercased()) { return false }
            if !widths.isEmpty, !widths.contains(record.width.lowercased()) { return false }
            if !sources.isEmpty, !sources.contains(record.source.lowercased()) { return false }
            if !collections.isEmpty, !record.collections.contains(where: { collections.contains($0.lowercased()) }) { return false }
            if weightMin != nil || weightMax != nil {
                let lo = weightMin ?? Int.min, hi = weightMax ?? Int.max
                if !record.faces.contains(where: { $0.weight >= lo && $0.weight <= hi }) { return false }
            }
            return true
        }

        // Name search: token-based match across family + styles + PostScript names +
        // foundry, ranked by relevance so the best match is first even without paging.
        // Falls back to fuzzy (subsequence) matching when nothing matches literally.
        let query = name?.trimmingCharacters(in: .whitespaces)
        var usedFuzzy = false
        let matches: [FontRecord]
        if let query, !query.isEmpty {
            let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
            var scored = attrFiltered.compactMap { record -> (FontRecord, Int)? in
                let score = nameScore(record, query: query, tokens: tokens)
                return score > 0 ? (record, score) : nil
            }
            if scored.isEmpty {
                usedFuzzy = true
                scored = attrFiltered.compactMap { record in
                    isSubsequence(query.replacingOccurrences(of: " ", with: ""),
                                  of: record.family.lowercased().replacingOccurrences(of: " ", with: ""))
                        ? (record, 1) : nil
                }
            }
            matches = scored
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.family.localizedCaseInsensitiveCompare($1.0.family) == .orderedAscending }
                .map(\.0)
        } else {
            matches = attrFiltered.sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
        }

        let page = Array(matches.dropFirst(offset).prefix(limit))

        struct FamilyDTO: Codable {
            let family, foundry, classification, width, source: String
            let collections: [String]
            let active: Bool
            let dateAdded: String?
            let faces: [FontFace]
            let specimenPngBase64: String?
        }
        struct FindResult: Codable {
            let total, offset, limit, returned: Int
            let families: [FamilyDTO]
        }

        let iso = ISO8601DateFormatter()
        var specimenContent: [Tool.Content] = []
        let families: [FamilyDTO] = page.map { record in
            var specimen: String?
            if includeSpecimen, let member = representativeMember(record) {
                specimen = SpecimenRenderer.pngBase64(for: member, text: specimenText)
                if let specimen {
                    specimenContent.append(.text("Specimen — \(record.family)"))
                    specimenContent.append(.image(specimen, "image/png"))
                }
            }
            return FamilyDTO(
                family: record.family,
                foundry: record.foundry,
                classification: record.classification,
                width: record.width,
                source: record.source,
                collections: record.collections,
                active: record.active,
                dateAdded: record.dateAdded.map { iso.string(from: $0) },
                faces: record.faces,
                specimenPngBase64: specimen
            )
        }

        let result = FindResult(total: matches.count, offset: offset, limit: limit, returned: families.count, families: families)

        let noFilters = query == nil && classifications.isEmpty && widths.isEmpty && sources.isEmpty && collections.isEmpty && weightMin == nil && weightMax == nil
        let summary: String
        if let query, !query.isEmpty {
            if usedFuzzy {
                summary = "No exact match for \"\(query)\" — showing \(families.count) closest by name (best first)."
            } else {
                summary = "\(matches.count) families matched \"\(query)\" (best first); returning \(families.count)."
            }
        } else if noFilters && matches.count > families.count {
            summary = "\(matches.count) families total; returning the first \(families.count) alphabetically. To find a specific font, pass `name` (e.g. name:\"Nichrome\") — you don't need to page through everything. Also filter by classification/width/foundry/weight; call list_attributes for valid values."
        } else {
            summary = "\(matches.count) families matched; returning \(families.count) (offset \(offset))."
        }
        return encoded(result, summary: summary, extraContent: specimenContent)
    }

    // MARK: - get_font

    static func getFont(_ records: [FontRecord], _ args: [String: Value]) -> CallTool.Result {
        var faceNames = stringArray(args["faces"])
        // Or fetch by family name, optionally narrowed to CSS weights and/or style words
        // ("Italic") — saves a find_fonts round trip.
        if let familyName = args["family"]?.stringValue {
            guard let record = records.first(where: { $0.family.caseInsensitiveCompare(familyName) == .orderedSame }) else {
                return errorResult("No family named '\(familyName)'. Use find_fonts with `name` to look it up.")
            }
            let weights = Set((args["weights"]?.arrayValue ?? []).compactMap(\.intValue))
            let styleWords = stringArray(args["styles"]).map { $0.lowercased() }
            // With `styles`, italics come back only when asked for — "Regular" shouldn't
            // also match "Regular Italic".
            let wantsItalic = styleWords.contains { $0.contains("italic") || $0.contains("oblique") }
            let picked = record.faces.filter { face in
                let style = face.style.lowercased()
                let isItalic = style.contains("italic") || style.contains("oblique")
                return (weights.isEmpty || weights.contains(face.weight))
                    && (styleWords.isEmpty || (styleWords.contains { style.contains($0) } && isItalic == wantsItalic))
            }
            guard !picked.isEmpty else {
                return errorResult("'\(record.family)' has no faces matching those weights/styles. Available: \(record.faces.map { "\($0.style) (\($0.weight))" }.joined(separator: ", ")).")
            }
            faceNames += picked.map(\.postScriptName)
        }
        guard !faceNames.isEmpty else {
            return errorResult("Pass `faces` (PostScript names from find_fonts) or `family` (optionally with `weights` / `styles`).")
        }
        let format = args["format"]?.stringValue?.lowercased() ?? "woff2"
        let destination = args["destination"]?.stringValue
        #if APPSTORE
        // The sandbox only allows writing into folders the user granted.
        if let destination, !isWritableInSandbox(destination) {
            return errorResult("`destination` must be inside the Delivery Folder set in Woffle (Settings → MCP Server) or one of its source folders. Omit `destination` to receive the font bytes instead.")
        }
        #endif
        let includeCSS = args["includeCSS"]?.boolValue ?? true
        let pathPrefix = args["cssPathPrefix"]?.stringValue ?? "./"
        let display = args["cssFontDisplay"]?.stringValue ?? "swap"

        let exportFormat: ExportFormat
        switch format {
        case "woff2": exportFormat = .woff2
        case "woff": exportFormat = .woff
        case "otf", "ttf", "native": exportFormat = .native
        default:
            return errorResult("Unknown format '\(format)'. Use woff2, woff, otf, or ttf.")
        }

        // Flatten the catalog into a PostScript-name → (member, family metadata) lookup.
        var lookup: [String: (member: FontMember, record: FontRecord)] = [:]
        for record in records {
            for member in record.members { lookup[member.postScriptName] = (member, record) }
        }

        struct GetFontFace: Codable {
            let postScriptName, family, style: String
            let weight: Int
            let format, filename: String
            let sizeBytes: Int
            let bytesBase64: String?
            let path: String?
            let css: String?
            let error: String?
        }
        struct GetFontResult: Codable { let faces: [GetFontFace] }

        var out: [GetFontFace] = []
        for psName in faceNames {
            guard let hit = lookup[psName] else {
                out.append(GetFontFace(postScriptName: psName, family: "", style: "", weight: 0, format: format, filename: "", sizeBytes: 0, bytesBase64: nil, path: nil, css: nil, error: "No face found with PostScript name '\(psName)'."))
                continue
            }
            let member = hit.member
            let cssWeight = CSSWeight.fromStyle(member.styleName)
            do {
                let (data, ext) = try FontConversionService.export(member, as: exportFormat)
                let filename = "\(FontConversionService.baseFilename(for: member)).\(ext)"
                let css = includeCSS ? FontFaceCSS.rule(family: hit.record.family, weight: cssWeight, style: member.styleName, ext: ext, filename: filename, pathPrefix: pathPrefix, display: display) : nil

                var writtenPath: String?
                var base64: String?
                if let destination {
                    writtenPath = try write(data, filename: filename, destination: destination)
                } else {
                    base64 = data.base64EncodedString()
                }

                out.append(GetFontFace(
                    postScriptName: psName,
                    family: hit.record.family,
                    style: member.styleName,
                    weight: cssWeight,
                    format: ext,
                    filename: filename,
                    sizeBytes: data.count,
                    bytesBase64: base64,
                    path: writtenPath,
                    css: css,
                    error: nil
                ))
            } catch {
                out.append(GetFontFace(postScriptName: psName, family: hit.record.family, style: member.styleName, weight: cssWeight, format: format, filename: "", sizeBytes: 0, bytesBase64: nil, path: nil, css: nil, error: error.localizedDescription))
            }
        }

        let delivered = out.filter { $0.error == nil }.count
        let summary = destination != nil
            ? "Wrote \(delivered)/\(out.count) face(s) to \(destination!)."
            : "Delivered \(delivered)/\(out.count) face(s) as base64 (see structuredContent)."
        return encoded(GetFontResult(faces: out), summary: summary)
    }

    // MARK: - Helpers

    static let deliveryFolderKey = "mcp.deliveryFolder"

    #if APPSTORE
    /// Whether `path` falls inside a folder the user granted: the MCP Delivery Folder or a
    /// source folder (the app holds security-scoped access to both).
    private static func isWritableInSandbox(_ path: String) -> Bool {
        let defaults = UserDefaults.standard
        let roots = (defaults.stringArray(forKey: "customFontDirectories") ?? [])
            + [defaults.string(forKey: deliveryFolderKey)].compactMap { $0 }
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        return roots.contains { root in
            let root = URL(fileURLWithPath: root).standardizedFileURL.path
            return target == root || target.hasPrefix(root + "/")
        }
    }
    #endif

    /// Writes `data` to `destination`. If `destination` is (or looks like) a directory,
    /// the file is written inside it using `filename`; otherwise `destination` is treated
    /// as the full file path. Intermediate directories are created as needed.
    private static func write(_ data: Data, filename: String, destination raw: String) throws -> String {
        let fm = FileManager.default
        let expanded = (raw as NSString).expandingTildeInPath
        let url: URL

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: expanded, isDirectory: &isDir)
        let looksLikeDir = raw.hasSuffix("/") || (!exists && (expanded as NSString).pathExtension.isEmpty)

        if (exists && isDir.boolValue) || looksLikeDir {
            try fm.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            url = URL(fileURLWithPath: expanded).appendingPathComponent(filename)
        } else {
            url = URL(fileURLWithPath: expanded)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: url)
        return url.path
    }

    /// Relevance score for a name query against a family. Higher is better; 0 means no
    /// match. Family-name signals dominate, but a match anywhere (style, PostScript name,
    /// foundry) still counts so multi-word and foundry queries work.
    private static func nameScore(_ record: FontRecord, query: String, tokens: [String]) -> Int {
        let family = record.family.lowercased()
        if family == query { return 100 }
        if family.hasPrefix(query) { return 85 }
        let words = family.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(query) { return 75 }
        if family.contains(query) { return 65 }
        guard !tokens.isEmpty else { return 0 }
        if tokens.allSatisfy({ family.contains($0) }) { return 55 }
        var haystack = "\(family) \(record.foundry.lowercased())"
        for face in record.faces { haystack += " \(face.style.lowercased()) \(face.postScriptName.lowercased())" }
        return tokens.allSatisfy({ haystack.contains($0) }) ? 40 : 0
    }

    /// True when every character of `needle` appears in `haystack` in order (typo/partial
    /// tolerant), used as the fuzzy fallback when nothing matches literally.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var index = haystack.startIndex
        for ch in needle {
            guard let found = haystack[index...].firstIndex(of: ch) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    /// The face best representing a family in previews: CSS weight closest to Regular (400).
    static func representativeMember(_ record: FontRecord) -> FontMember? {
        record.members.min {
            abs(CSSWeight.fromStyle($0.styleName) - 400) < abs(CSSWeight.fromStyle($1.styleName) - 400)
        }
    }

    /// Accepts either a JSON array of strings or a single string, returning `[String]`.
    static func stringArray(_ value: Value?) -> [String] {
        guard let value else { return [] }
        if let array = value.arrayValue { return array.compactMap { $0.stringValue } }
        if let single = value.stringValue { return [single] }
        return []
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }

    static func encoded<T: Codable>(_ payload: T, summary: String, extraContent: [Tool.Content] = []) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var content: [Tool.Content] = [.text("\(summary)\n\n\(json)")]
        content.append(contentsOf: extraContent)
        let structured = try? Value(payload)
        return CallTool.Result(content: content, structuredContent: structured)
    }
}
