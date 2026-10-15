import Foundation
import AppKit
import UniformTypeIdentifiers

/// Runs export/convert operations off the main thread and reports progress via ToastCenter.
@MainActor
final class ConversionManager: ObservableObject {
    private let toast: ToastCenter

    /// Drives presentation of the Convert sheet.
    @Published var showConvert = false
    /// Set when an export/convert is blocked awaiting the one-time licensing acknowledgement.
    @Published var pendingLicenseConfirmation = false
    private var pendingAction: (() -> Void)?
    private let licenseKey = "hasAcknowledgedFontLicensing"

    init(toast: ToastCenter) {
        self.toast = toast
    }

    // MARK: - Export (outbound "Download as…")

    func download(_ member: FontMember, as format: ExportFormat) {
        guard member.isExportable else {
            toast.flash(FontConversionError.protectedSystemFont.localizedDescription, isError: true)
            return
        }
        guard ensureLicenseAck({ [weak self] in self?.download(member, as: format) }) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = FontConversionService.suggestedFilename(for: member, format: format)
        panel.canCreateDirectories = true
        panel.title = "Download Font"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let token = toast.begin("Exporting \(member.styleName)…")
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let result = try FontConversionService.export(member, as: format)
                    let finalURL = destination.pathExtension.isEmpty ? destination.appendingPathExtension(result.ext) : destination
                    try result.data.write(to: finalURL)
                    return finalURL
                }.value
                toast.finish(token, success: true, message: "Saved \(url.lastPathComponent)", reveal: url)
            } catch {
                toast.finish(token, success: false, message: error.localizedDescription)
            }
        }
    }

    func downloadAll(_ members: [FontMember], family: String, as format: ExportFormat) {
        let members = members.filter(\.isExportable)
        guard !members.isEmpty else {
            toast.flash(FontConversionError.protectedSystemFont.localizedDescription, isError: true)
            return
        }
        guard ensureLicenseAck({ [weak self] in self?.downloadAll(members, family: family, as: format) }) else { return }

        guard let directory = chooseDirectory(message: "Choose a folder to export “\(family)” styles into") else { return }

        let token = toast.begin("Exporting \(members.count) styles…")
        Task {
            var used = Set<String>()
            var saved = 0
            var failed = 0
            for (index, member) in members.enumerated() {
                toast.update(token, message: "Exporting \(index + 1) of \(members.count)…")
                if await export(member, as: format, into: directory, used: &used) { saved += 1 } else { failed += 1 }
            }
            finishExport(token, saved: saved, failed: failed, reveal: directory)
        }
    }

    /// Export every style of multiple families into one folder (a subfolder per family).
    func downloadMany(_ fonts: [FontItem], as format: ExportFormat) {
        // Apple's system fonts are skipped (not exportable); the rest export as usual.
        let fonts = fonts.filter { !$0.exportableMembers.isEmpty }
        guard !fonts.isEmpty else {
            toast.flash(FontConversionError.protectedSystemFont.localizedDescription, isError: true)
            return
        }
        guard ensureLicenseAck({ [weak self] in self?.downloadMany(fonts, as: format) }) else { return }

        guard let root = chooseDirectory(message: "Choose a folder to export \(fonts.count) font families into") else { return }

        let total = fonts.reduce(0) { $0 + $1.exportableMembers.count }
        let token = toast.begin("Exporting \(total) styles…")
        Task {
            var saved = 0
            var failed = 0
            var index = 0
            for font in fonts {
                let folderName = font.familyName.replacingOccurrences(of: "/", with: "-")
                let familyDirectory = root.appendingPathComponent(folderName, isDirectory: true)
                try? FileManager.default.createDirectory(at: familyDirectory, withIntermediateDirectories: true)
                var used = Set<String>()
                for member in font.exportableMembers {
                    index += 1
                    toast.update(token, message: "Exporting \(index) of \(total)…")
                    if await export(member, as: format, into: familyDirectory, used: &used) { saved += 1 } else { failed += 1 }
                }
            }
            finishExport(token, saved: saved, failed: failed, reveal: root)
        }
    }

    private func export(_ member: FontMember, as format: ExportFormat, into directory: URL, used: inout Set<String>) async -> Bool {
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try FontConversionService.export(member, as: format)
            }.value
            let name = "\(FontConversionService.baseFilename(for: member)).\(result.ext)"
            let url = uniqueURL(in: directory, name: name, used: &used)
            try await Task.detached(priority: .userInitiated) { try result.data.write(to: url) }.value
            return true
        } catch {
            return false
        }
    }

    private func finishExport(_ token: Int, saved: Int, failed: Int, reveal: URL) {
        if failed == 0 {
            toast.finish(token, success: true, message: "Exported \(saved) file\(saved == 1 ? "" : "s")", reveal: reveal)
        } else {
            toast.finish(token, success: false, message: "Exported \(saved), \(failed) failed")
        }
    }

    // MARK: - Convert (either direction)

    /// Convert font files to `format`. Desktop (OTF/TTF) results are also activated and
    /// tracked in the library; web (WOFF/WOFF2) results are just saved.
    func convert(_ urls: [URL], to format: ExportFormat, into fontService: FontService) {
        guard !urls.isEmpty else { return }
        guard ensureLicenseAck({ [weak self] in self?.convert(urls, to: format, into: fontService) }) else { return }

        let addsToLibrary = (format == .native)

        if urls.count == 1 {
            let source = urls[0]
            let token = toast.begin("Converting \(source.lastPathComponent)…")
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try FontConversionService.convert(source, to: format)
                    }.value

                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent).\(result.ext)"
                    panel.canCreateDirectories = true
                    panel.title = "Save Converted Font"
                    guard panel.runModal() == .OK, let destination = panel.url else { toast.dismiss(); return }
                    let url = destination.pathExtension.isEmpty ? destination.appendingPathExtension(result.ext) : destination
                    try await Task.detached(priority: .userInitiated) { try result.data.write(to: url) }.value
                    if addsToLibrary {
                        fontService.addImportedFonts([url])
                        toast.finish(token, success: true, message: "Converted & activated \(url.lastPathComponent)", reveal: url)
                    } else {
                        toast.finish(token, success: true, message: "Saved \(url.lastPathComponent)", reveal: url)
                    }
                } catch {
                    toast.finish(token, success: false, message: error.localizedDescription)
                }
            }
            return
        }

        guard let directory = chooseDirectory(message: "Choose a folder for the converted fonts") else { return }

        let token = toast.begin("Converting \(urls.count) fonts…")
        Task {
            var used = Set<String>()
            var savedURLs: [URL] = []
            var failed = 0
            for (index, source) in urls.enumerated() {
                toast.update(token, message: "Converting \(index + 1) of \(urls.count)…")
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try FontConversionService.convert(source, to: format)
                    }.value
                    let url = uniqueURL(in: directory, name: "\(source.deletingPathExtension().lastPathComponent).\(result.ext)", used: &used)
                    try await Task.detached(priority: .userInitiated) { try result.data.write(to: url) }.value
                    savedURLs.append(url)
                } catch {
                    failed += 1
                }
            }
            if addsToLibrary { fontService.addImportedFonts(savedURLs) }
            let verb = addsToLibrary ? "Converted & activated" : "Converted"
            if failed == 0 {
                toast.finish(token, success: true, message: "\(verb) \(savedURLs.count) font\(savedURLs.count == 1 ? "" : "s")", reveal: directory)
            } else {
                toast.finish(token, success: false, message: "Converted \(savedURLs.count), \(failed) failed")
            }
        }
    }

    // MARK: - Licensing acknowledgement

    /// Returns true if the action may proceed; otherwise stashes it and prompts once.
    private func ensureLicenseAck(_ retry: @escaping () -> Void) -> Bool {
        if UserDefaults.standard.bool(forKey: licenseKey) { return true }
        pendingAction = retry
        pendingLicenseConfirmation = true
        return false
    }

    func confirmLicensing() {
        UserDefaults.standard.set(true, forKey: licenseKey)
        pendingLicenseConfirmation = false
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func cancelLicensing() {
        pendingLicenseConfirmation = false
        pendingAction = nil
    }

    // MARK: - Helpers

    private func chooseDirectory(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// A destination URL that doesn't collide with an existing file or one already
    /// written in this batch (appends " 2", " 3", … as needed).
    private func uniqueURL(in directory: URL, name: String, used: inout Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 1
        while used.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        }
        used.insert(candidate.lowercased())
        return directory.appendingPathComponent(candidate)
    }
}
