import Foundation

/// One curated wallpaper from the hosted Featured catalog.
struct FeaturedItem: Codable, Equatable {
    let id: String
    let title: String
    let category: String
    let videoURL: URL
    let thumbnailURL: URL

    enum CodingKeys: String, CodingKey {
        case id, title, category
        case videoURL = "video_url"
        case thumbnailURL = "thumbnail_url"
    }
}

/// Top-level shape of `featured.json` hosted on GitHub Pages.
private struct FeaturedCatalog: Codable {
    let version: Int
    let items: [FeaturedItem]
}

/// Talks to the hosted Featured catalog on GitHub Pages and manages
/// local downloads of any items the user picks. Files land in the same
/// `~/Movies/LiveWall/Library/Featured/` folder so the existing Library
/// tab also picks them up automatically.
final class FeaturedService {

    static let shared = FeaturedService()

    /// Where the catalog lives. Update if the project ever moves.
    private let catalogURL = URL(string:
        "https://brendanrong.github.io/livewall/featured.json")!

    private(set) var items: [FeaturedItem] = []

    static let catalogLoadedNotification = Notification.Name("LiveWall.featuredCatalogLoaded")

    /// Subfolder of `~/Movies/LiveWall/Library/` where downloaded
    /// Featured items live. Sits inside Library/ so the Library
    /// scanner shows them too.
    var downloadsFolder: URL {
        LibraryService.shared.rootFolder
            .appendingPathComponent("Featured", isDirectory: true)
    }

    /// In-flight downloads keyed by item id, so two clicks on the same
    /// card don't kick off two parallel downloads.
    private var inFlight: [String: URLSessionDownloadTask] = [:]

    private init() {}

    // MARK: - Catalog

    /// Fetch and decode the catalog JSON. `completion` is called on the
    /// main queue.
    func loadCatalog(completion: @escaping (Result<[FeaturedItem], Error>) -> Void) {
        var req = URLRequest(url: catalogURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(Self.error("Empty catalog response")))
                    return
                }
                do {
                    let catalog = try JSONDecoder().decode(FeaturedCatalog.self, from: data)
                    self.items = catalog.items
                    NotificationCenter.default.post(
                        name: Self.catalogLoadedNotification, object: nil)
                    completion(.success(catalog.items))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Local files

    func localURL(for item: FeaturedItem) -> URL {
        let ext = item.videoURL.pathExtension.isEmpty ? "mp4" : item.videoURL.pathExtension
        return downloadsFolder.appendingPathComponent("\(item.id).\(ext)")
    }

    func isDownloaded(_ item: FeaturedItem) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: item).path)
    }

    func isDownloading(_ item: FeaturedItem) -> Bool {
        inFlight[item.id] != nil
    }

    /// Download the item's video to `localURL(for:)`. Idempotent — if
    /// already downloaded, fires completion immediately with the local
    /// URL. `progress` ticks 0...1 on the main queue while downloading.
    func download(_ item: FeaturedItem,
                  progress: ((Double) -> Void)? = nil,
                  completion: @escaping (Result<URL, Error>) -> Void) {

        let dest = localURL(for: item)
        if FileManager.default.fileExists(atPath: dest.path) {
            DispatchQueue.main.async { completion(.success(dest)) }
            return
        }
        if inFlight[item.id] != nil {
            DispatchQueue.main.async {
                completion(.failure(Self.error("Already downloading")))
            }
            return
        }

        try? FileManager.default.createDirectory(
            at: downloadsFolder, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: item.videoURL) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            // CRITICAL: do the move synchronously inside the completion
            // closure. URLSession deletes the temp file the instant
            // this closure returns, so dispatching to main first would
            // leave us trying to move a file that no longer exists.
            self.inFlight.removeValue(forKey: item.id)
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    completion(.failure(Self.error("Download finished with no file")))
                }
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)  // clobber any partial
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async { completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        inFlight[item.id] = task

        // Forward bytes-downloaded progress to the caller for UI feedback.
        // URLSessionTask.progress is KVO-observable; observe with a
        // wrapper that drops itself once the task ends.
        if let progress = progress {
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                DispatchQueue.main.async { progress(p.fractionCompleted) }
            }
            // Tie observation lifetime to the task so it gets released
            // once the task is deallocated.
            objc_setAssociatedObject(task, &Self.observationKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        task.resume()
    }

    func deleteLocalCopy(_ item: FeaturedItem) throws {
        let url = localURL(for: item)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static var observationKey: UInt8 = 0

    private static func error(_ msg: String) -> Error {
        NSError(domain: "LiveWall.Featured", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
