import Foundation

/// One video on disk that LiveWall can use as a wallpaper. Today this is
/// always a local file — produced by the Generate pane, dropped into the
/// folder by the user, or scanned from somewhere else on the system.
struct LibraryItem: Equatable {
    let id: String          // unique stable id (the file path)
    let title: String       // pretty filename
    let category: String?   // parent folder (e.g. "Generated")
    let videoURL: URL       // file:// URL on disk
}

/// Scans the user's `~/Movies/LiveWall/Library/` folder for usable wallpapers
/// and hands them back as a flat list. Each subfolder shows up as a category
/// label on its items so the UI can group them.
final class LibraryService {

    static let shared = LibraryService()

    /// Top-level folder that holds all local wallpaper content.
    /// `Generated/` lives inside this for AI-generated clips; the user
    /// can drop anything else in here too.
    var rootFolder: URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies")
        return movies
            .appendingPathComponent("LiveWall", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    private(set) var items: [LibraryItem] = []

    static let manifestLoadedNotification = Notification.Name("LiveWall.libraryManifestLoaded")

    private init() {}

    /// Re-scan the library folder. `completion` is called on the main queue.
    func loadManifest(completion: @escaping (Result<[LibraryItem], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(
                at: self.rootFolder, withIntermediateDirectories: true)
            let scanned = self.scanFolder(self.rootFolder)
            DispatchQueue.main.async {
                self.items = scanned
                NotificationCenter.default.post(
                    name: Self.manifestLoadedNotification, object: nil)
                completion(.success(scanned))
            }
        }
    }

    /// Local file URL for an item. Trivial today since everything's local —
    /// kept as a method so existing callers don't need rewriting.
    func localURL(for item: LibraryItem) -> URL { item.videoURL }

    /// Always true now — every item is on disk.
    func isDownloaded(_: LibraryItem) -> Bool { true }

    /// Never — there's no async fetch to be in flight for local files.
    func isDownloading(_: LibraryItem) -> Bool { false }

    func deleteLocalCopy(_ item: LibraryItem) throws {
        try FileManager.default.removeItem(at: item.videoURL)
    }

    // MARK: - Private

    private func scanFolder(_ folder: URL) -> [LibraryItem] {
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        var collected: [LibraryItem] = []

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard exts.contains(url.pathExtension.lowercased()) else { continue }

            let categoryFolder = url.deletingLastPathComponent()
            let category: String?
            if categoryFolder == folder {
                category = nil
            } else {
                category = categoryFolder.lastPathComponent
            }

            // Strip a trailing "-1762345678" timestamp suffix (added by
            // LeonardoService for filename uniqueness) before prettifying.
            var rawName = url.deletingPathExtension().lastPathComponent
            if let range = rawName.range(of: #"-\d{8,}$"#, options: .regularExpression) {
                rawName = String(rawName[..<range.lowerBound])
            }
            let title = rawName
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")

            collected.append(LibraryItem(
                id: url.path,
                title: title,
                category: category,
                videoURL: url
            ))
        }

        // Newest first.
        return collected.sorted { (a, b) in
            let aDate = (try? a.videoURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bDate = (try? b.videoURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return aDate > bDate
        }
    }
}
