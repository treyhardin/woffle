import Foundation

/// Persists access to user-chosen files and folders as security-scoped bookmarks, keyed by
/// path. The sandboxed App Store build needs this to reach them again after a relaunch; the
/// open-source build uses the same code so both builds behave identically.
@MainActor
final class BookmarkStore {
    private let defaultsKey: String
    private var bookmarks: [String: Data]
    /// URLs we've started security-scoped access for, so it can be released on removal.
    private var accessing: [String: URL] = [:]

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// Re-opens access to each path from its bookmark. Paths saved before bookmarks existed
    /// get one now — possible outside the sandbox, where the path is still readable.
    func startAccessing(_ paths: [String]) {
        for path in paths where accessing[path] == nil {
            if bookmarks[path] == nil {
                guard let data = Self.makeBookmark(for: URL(fileURLWithPath: path)) else { continue }
                bookmarks[path] = data
            }
            guard let data = bookmarks[path] else { continue }
            var isStale = false
            guard let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale))
                    ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            accessing[path] = url
            // A stale bookmark still resolves; refresh it while we have access.
            if isStale, let fresh = Self.makeBookmark(for: url) { bookmarks[path] = fresh }
        }
        save()
    }

    /// Records access to `url`. Call while access is granted — right after an open/save
    /// panel or a drop.
    func add(_ url: URL) {
        guard let data = Self.makeBookmark(for: url) else { return }
        bookmarks[url.path] = data
        if accessing[url.path] == nil, url.startAccessingSecurityScopedResource() {
            accessing[url.path] = url
        }
        save()
    }

    func remove(_ path: String) {
        accessing.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        bookmarks.removeValue(forKey: path)
        save()
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    /// Security-scoped when the app is sandboxed; a plain bookmark otherwise.
    private static func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}
