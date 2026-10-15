import Foundation
import CoreText
import Compression

/// Output formats a font can be exported to.
enum ExportFormat: String, CaseIterable, Identifiable {
    case native
    case woff
    case woff2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: return "Desktop (OTF / TTF)"
        case .woff: return "WOFF"
        case .woff2: return "WOFF2"
        }
    }

    /// Formats wired up for export.
    static let supported: [ExportFormat] = [.native, .woff, .woff2]
}

enum FontConversionError: LocalizedError {
    case cannotCreateFont
    case noTables
    case invalidWebFont(String)
    case unsupportedFormat(String)
    case compressionFailed
    case decompressionFailed
    case protectedSystemFont

    var errorDescription: String? {
        switch self {
        case .cannotCreateFont: return "Couldn't read this font's data."
        case .noTables: return "This font has no readable tables."
        case .invalidWebFont(let why): return "Not a usable web font: \(why)."
        case .unsupportedFormat(let what): return "\(what) isn't supported yet."
        case .compressionFailed: return "Compression failed."
        case .decompressionFailed: return "This web font's data couldn't be decompressed."
        case .protectedSystemFont: return "Apple's system fonts are licensed for use on this Mac only, so they can't be exported or converted."
        }
    }
}

/// Pure font-format plumbing — no app types, so it can be unit-tested in isolation.
/// Handles single-face SFNT assembly and WOFF 1.0 wrap/unwrap. WOFF2 is layered on in Step B.
enum FontConversionEngine {

    // MARK: - Public API

    /// Assemble a standalone single-face SFNT (OTF/TTF) from a CTFont, extracting one
    /// face even when the source is a .ttc/.dfont collection.
    static func assembleSFNT(from font: CTFont) throws -> Data {
        guard let cfTables = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)) else {
            throw FontConversionError.noTables
        }
        let count = CFArrayGetCount(cfTables)
        var tables: [(tag: UInt32, data: [UInt8])] = []
        var hasGlyf = false
        var hasCFF = false
        for i in 0..<count {
            let raw = CFArrayGetValueAtIndex(cfTables, i)
            let tag = UInt32(truncatingIfNeeded: Int(bitPattern: raw))
            guard let cfData = CTFontCopyTable(font, CTFontTableTag(tag), CTFontTableOptions(rawValue: 0)) else { continue }
            if tag == tag4("glyf") { hasGlyf = true }
            if tag == tag4("CFF ") || tag == tag4("CFF2") { hasCFF = true }
            tables.append((tag, [UInt8](cfData as Data)))
        }
        guard !tables.isEmpty else { throw FontConversionError.noTables }
        guard hasGlyf || hasCFF else {
            // No outline table (e.g. bitmap-only/SVG-only font) — can't build a valid SFNT.
            throw FontConversionError.unsupportedFormat("This font has no TrueType or PostScript outlines")
        }
        let flavor: UInt32 = hasGlyf ? 0x0001_0000 : tag4("OTTO")
        return Data(buildSFNT(flavor: flavor, tables: tables))
    }

    /// Wrap an SFNT (OTF/TTF) into a WOFF 1.0 container.
    static func wrapWOFF(sfnt: Data) throws -> Data {
        let b = [UInt8](sfnt)
        guard b.count >= 12 else { throw FontConversionError.invalidWebFont("truncated") }
        let flavor = be32(b, 0)
        let numTables = Int(be16(b, 4))

        var dir: [(tag: UInt32, checksum: UInt32, offset: Int, length: Int)] = []
        var p = 12
        for _ in 0..<numTables {
            guard p + 16 <= b.count else { throw FontConversionError.invalidWebFont("bad directory") }
            dir.append((be32(b, p), be32(b, p + 4), Int(be32(b, p + 8)), Int(be32(b, p + 12))))
            p += 16
        }

        let numT = numTables
        var dataOffset = 44 + 20 * numT
        var totalSfntSize = 12 + 16 * numTables
        var entries: [(tag: UInt32, offset: Int, compLength: Int, origLength: Int, checksum: UInt32)] = []
        var body: [UInt8] = []

        for d in dir {
            guard d.offset + d.length <= b.count else { throw FontConversionError.invalidWebFont("table out of range") }
            let table = Array(b[d.offset ..< d.offset + d.length])
            totalSfntSize += align4(d.length)
            let compressed = Zlib.zlibCompress(Data(table))
            let stored: [UInt8] = compressed.count < table.count ? [UInt8](compressed) : table
            entries.append((d.tag, dataOffset, stored.count, d.length, d.checksum))
            var blk = stored
            while blk.count % 4 != 0 { blk.append(0) }
            body += blk
            dataOffset += blk.count
        }

        let totalLength = 44 + 20 * numT + body.count
        var out: [UInt8] = []
        out += be32bytes(tag4("wOFF"))
        out += be32bytes(flavor)
        out += be32bytes(UInt32(totalLength))
        out += be16bytes(UInt16(numT))
        out += be16bytes(0)                       // reserved
        out += be32bytes(UInt32(totalSfntSize))
        out += be16bytes(1)                       // majorVersion
        out += be16bytes(0)                       // minorVersion
        out += be32bytes(0)                       // metaOffset
        out += be32bytes(0)                       // metaLength
        out += be32bytes(0)                       // metaOrigLength
        out += be32bytes(0)                       // privOffset
        out += be32bytes(0)                       // privLength
        for e in entries {
            out += be32bytes(e.tag)
            out += be32bytes(UInt32(e.offset))
            out += be32bytes(UInt32(e.compLength))
            out += be32bytes(UInt32(e.origLength))
            out += be32bytes(e.checksum)
        }
        out += body
        return Data(out)
    }

    /// Unwrap a WOFF 1.0 container back into an SFNT (OTF/TTF).
    static func unwrapWOFF(woff: Data) throws -> Data {
        let b = [UInt8](woff)
        guard b.count >= 44, be32(b, 0) == tag4("wOFF") else {
            throw FontConversionError.invalidWebFont("not a WOFF file")
        }
        let flavor = be32(b, 4)
        let numTables = Int(be16(b, 12))
        var p = 44
        var tables: [(tag: UInt32, data: [UInt8])] = []
        for _ in 0..<numTables {
            guard p + 20 <= b.count else { throw FontConversionError.invalidWebFont("bad directory") }
            let tag = be32(b, p)
            let offset = Int(be32(b, p + 4))
            let compLength = Int(be32(b, p + 8))
            let origLength = Int(be32(b, p + 12))
            p += 20
            guard offset + compLength <= b.count else { throw FontConversionError.invalidWebFont("table out of range") }
            let blk = Array(b[offset ..< offset + compLength])
            let data: [UInt8]
            if compLength != origLength {
                guard let dec = Zlib.zlibDecompress(Data(blk), expected: origLength) else {
                    throw FontConversionError.decompressionFailed
                }
                data = [UInt8](dec)
            } else {
                data = blk
            }
            tables.append((tag, data))
        }
        return Data(buildSFNT(flavor: flavor, tables: tables))
    }

    /// Decode any web/desktop font file at `url` into an installable SFNT.
    /// Returns the SFNT bytes and whether it is TrueType-flavored.
    static func webFontToSFNT(_ url: URL) throws -> (data: Data, isTrueType: Bool) {
        let data = try Data(contentsOf: url)
        let b = [UInt8](data.prefix(4))
        guard b.count == 4 else { throw FontConversionError.invalidWebFont("truncated") }
        let sig = be32(b, 0)
        if sig == tag4("wOFF") {
            let sfnt = try unwrapWOFF(woff: data)
            return (sfnt, isTrueType(sfnt))
        }
        if sig == tag4("wOF2") {
            throw FontConversionError.unsupportedFormat("WOFF2 (added in Step B)")
        }
        if sig == tag4("ttcf") {
            throw FontConversionError.unsupportedFormat("Font collections (.ttc)")
        }
        if sig == 0x0001_0000 || sig == tag4("OTTO") || sig == tag4("true") || sig == tag4("typ1") {
            return (data, isTrueType(data))
        }
        throw FontConversionError.invalidWebFont("unrecognized signature")
    }

    static func isTrueType(_ sfnt: Data) -> Bool {
        let b = [UInt8](sfnt.prefix(4))
        guard b.count == 4 else { return true }
        return be32(b, 0) != tag4("OTTO")
    }

    // MARK: - SFNT builder

    /// Build a valid SFNT from a set of tables: sorted directory, padded tables,
    /// per-table checksums, and a corrected head.checkSumAdjustment.
    private static func buildSFNT(flavor: UInt32, tables rawTables: [(tag: UInt32, data: [UInt8])]) -> [UInt8] {
        var tables = rawTables.sorted { $0.tag < $1.tag }

        // Zero head.checkSumAdjustment before any checksum is computed.
        if let headIndex = tables.firstIndex(where: { $0.tag == tag4("head") }), tables[headIndex].data.count >= 12 {
            tables[headIndex].data[8] = 0
            tables[headIndex].data[9] = 0
            tables[headIndex].data[10] = 0
            tables[headIndex].data[11] = 0
        }

        let numTables = tables.count
        var maxPow2 = 1
        var entrySelector: UInt16 = 0
        while maxPow2 * 2 <= numTables {
            maxPow2 *= 2
            entrySelector += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let rangeShift = UInt16(numTables * 16) &- searchRange

        var offset = 12 + 16 * numTables
        var entries: [(tag: UInt32, checksum: UInt32, offset: Int, length: Int)] = []
        var body: [UInt8] = []
        var headOffset: Int?
        for t in tables {
            var padded = t.data
            while padded.count % 4 != 0 { padded.append(0) }
            let checksum = checksum(padded)
            entries.append((t.tag, checksum, offset, t.data.count))
            if t.tag == tag4("head") { headOffset = offset }
            body += padded
            offset += padded.count
        }

        var out: [UInt8] = []
        out += be32bytes(flavor)
        out += be16bytes(UInt16(numTables))
        out += be16bytes(searchRange)
        out += be16bytes(entrySelector)
        out += be16bytes(rangeShift)
        for e in entries {
            out += be32bytes(e.tag)
            out += be32bytes(e.checksum)
            out += be32bytes(UInt32(e.offset))
            out += be32bytes(UInt32(e.length))
        }
        out += body

        if let headOffset {
            let total = checksum(out)
            let adjustment = 0xB1B0_AFBA &- total
            let bytes = be32bytes(adjustment)
            out[headOffset + 8] = bytes[0]
            out[headOffset + 9] = bytes[1]
            out[headOffset + 10] = bytes[2]
            out[headOffset + 11] = bytes[3]
        }
        return out
    }

    // MARK: - Byte helpers

    private static func tag4(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        precondition(b.count == 4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private static func be16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func be16bytes(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    private static func be32bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func align4(_ x: Int) -> Int { (x + 3) & ~3 }

    private static func checksum(_ b: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        let n = b.count
        while i < n {
            let b0 = UInt32(b[i])
            let b1 = i + 1 < n ? UInt32(b[i + 1]) : 0
            let b2 = i + 2 < n ? UInt32(b[i + 2]) : 0
            let b3 = i + 3 < n ? UInt32(b[i + 3]) : 0
            sum = sum &+ (b0 << 24 | b1 << 16 | b2 << 8 | b3)
            i += 4
        }
        return sum
    }
}

/// zlib (RFC 1950) compression built on the Compression framework's raw DEFLATE,
/// with a hand-written 2-byte header and Adler-32 trailer.
enum Zlib {
    static func zlibCompress(_ input: Data) -> Data {
        guard let raw = process(input, operation: COMPRESSION_STREAM_ENCODE) else { return input }
        var out = Data([0x78, 0x9C])
        out.append(raw)
        var adler = Zlib.adler32(input).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    static func zlibDecompress(_ input: Data, expected: Int) -> Data? {
        guard input.count >= 6 else { return nil }
        let raw = input.subdata(in: input.index(input.startIndex, offsetBy: 2) ..< input.index(input.endIndex, offsetBy: -4))
        return process(raw, operation: COMPRESSION_STREAM_DECODE, expected: expected)
    }

    private static func process(_ input: Data, operation: compression_stream_operation, expected: Int = 0) -> Data? {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        let dstCapacity = max(16_384, expected > 0 ? expected : input.count)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            var output = Data()
            stream.src_ptr = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = srcRaw.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = dst
                stream.dst_size = dstCapacity
                status = compression_stream_process(&stream, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstCapacity - stream.dst_size
                    if produced > 0 { output.append(dst, count: produced) }
                default:
                    return nil
                }
            } while status == COMPRESSION_STATUS_OK
            return output
        }
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65_521
        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }
}
