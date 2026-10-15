import Foundation
import TipKit

/// Where the app keeps its data, and the throwaway "Preview" mode used by the open-source
/// Debug build ("Font Manager (Preview)", its own bundle ID): every launch starts from a
/// clean slate — settings, collections, edits and tips are wiped — so first-run flows can
/// be tested. The App Store build (and open-source Release) persist normally.
enum AppEnvironment {
    #if DEBUG && !APPSTORE
    static let isPreview = true
    #else
    static let isPreview = false
    #endif

    /// Folder for overrides.json / collections.json.
    static var supportDirectory: URL {
        let base = isPreview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("FontManagerPreview", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Font Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Call first thing at launch, before anything reads settings.
    static func resetIfPreview() {
        guard isPreview, let bundleID = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        try? FileManager.default.removeItem(at: supportDirectory)
        try? Tips.resetDatastore()
    }
}
