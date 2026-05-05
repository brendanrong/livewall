import Foundation

// MARK: - Models / resolutions exposed in the UI

/// One of the three video models the user can pick in the Generate pane.
/// Each carries its own duration list and supported resolutions because
/// the underlying Leonardo models all have different constraints.
enum LeonardoModel: String, CaseIterable {
    case kling30        = "kling-3.0"
    case seedance20Fast = "seedance-2.0-fast"
    case veo31Fast      = "veo-3.1-fast"

    var displayName: String {
        switch self {
        case .kling30:        return "Kling 3.0"
        case .seedance20Fast: return "Seedance 2.0 Fast"
        case .veo31Fast:      return "Veo 3.1 Fast"
        }
    }

    /// Allowed durations in seconds, ordered as we want them to appear.
    var durations: [Int] {
        switch self {
        case .kling30:        return [3, 5, 7, 10, 15]
        case .seedance20Fast: return [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        case .veo31Fast:      return [4, 6, 8]
        }
    }

    var defaultDuration: Int {
        switch self {
        case .kling30:        return 5
        case .seedance20Fast: return 8
        case .veo31Fast:      return 8
        }
    }

    /// Resolutions the model supports. Order = order shown in the dropdown.
    var resolutions: [LeonardoResolution] {
        switch self {
        case .kling30:        return [.fullHD, .uhd4K]
        case .seedance20Fast: return [.fullHD]
        case .veo31Fast:      return [.fullHD, .uhd4K]
        }
    }

    var defaultResolution: LeonardoResolution { .fullHD }
}

/// 16:9 video output sizes we expose.
enum LeonardoResolution: String, CaseIterable {
    case fullHD = "RESOLUTION_1080" // 1920x1080
    case uhd4K  = "RESOLUTION_2160" // 3840x2160

    var displayName: String {
        switch self {
        case .fullHD: return "1080p"
        case .uhd4K:  return "4K"
        }
    }

    var width: Int {
        switch self {
        case .fullHD: return 1920
        case .uhd4K:  return 3840
        }
    }

    var height: Int {
        switch self {
        case .fullHD: return 1080
        case .uhd4K:  return 2160
        }
    }
}

// MARK: - Service

/// Talks to Leonardo.AI's v2 video-generation endpoint. The pipeline is
/// single-step now (text → video) for all three supported models. Each
/// generation:
///   1. POST /v2/generations with model + parameters
///   2. Poll /v1/generations/{id} until COMPLETE
///   3. Download the .mp4 to ~/Movies/LiveWall/Generated/
final class LeonardoService {

    static let shared = LeonardoService()

    enum Phase: Equatable {
        case idle
        case starting
        case generating
        case downloading
        case complete(URL)
        case failed(String)

        var label: String {
            switch self {
            case .idle:            return ""
            case .starting:        return "Starting…"
            case .generating:      return "Generating video…"
            case .downloading:     return "Downloading video…"
            case .complete:        return "Done"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
    }

    static let phaseChangedNotification = Notification.Name("LiveWall.leonardoPhaseChanged")

    private let v2BaseURL = URL(string: "https://cloud.leonardo.ai/api/rest/v2")!
    private let v1BaseURL = URL(string: "https://cloud.leonardo.ai/api/rest/v1")!
    private var cancelled = false

    private(set) var phase: Phase = .idle {
        didSet {
            NotificationCenter.default.post(name: Self.phaseChangedNotification, object: nil)
        }
    }

    private init() {}

    /// Output folder for generated clips. Sits inside the Library folder
    /// so the scanner picks them up automatically and tags them with the
    /// "Generated" category.
    var outputFolder: URL {
        LibraryService.shared.rootFolder
            .appendingPathComponent("Generated", isDirectory: true)
    }

    /// Cancel an in-flight generation. The next poll will fail and the
    /// pipeline finishes with `.failed("Cancelled")`.
    func cancel() {
        cancelled = true
    }

    /// Run the full text → video → download pipeline for the given model.
    /// `completion` fires once on the main queue with the local file URL
    /// of the finished clip, or an error.
    func generate(prompt: String,
                  model: LeonardoModel,
                  resolution: LeonardoResolution,
                  duration: Int,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        cancelled = false
        phase = .starting
        try? FileManager.default.createDirectory(
            at: outputFolder, withIntermediateDirectories: true)

        startGeneration(prompt: prompt, model: model,
                        resolution: resolution, duration: duration) { [weak self] result in
            guard let self = self else { return }
            if self.cancelled { self.fail("Cancelled", completion); return }
            switch result {
            case .failure(let e):
                self.fail(e.localizedDescription, completion)
            case .success(let id):
                self.phase = .generating
                self.pollGeneration(id: id) { [weak self] poll in
                    guard let self = self else { return }
                    if self.cancelled { self.fail("Cancelled", completion); return }
                    switch poll {
                    case .failure(let e):
                        self.fail(e.localizedDescription, completion)
                    case .success(let videoURL):
                        self.phase = .downloading
                        self.downloadVideo(remote: videoURL, prompt: prompt,
                                           completion: completion)
                    }
                }
            }
        }
    }

    // MARK: - Pipeline steps

    private func startGeneration(prompt: String,
                                 model: LeonardoModel,
                                 resolution: LeonardoResolution,
                                 duration: Int,
                                 completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: v2BaseURL.appendingPathComponent("generations"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.leonardoAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        // Note: not sending `mode`. Each model has different rules for what
        // mode strings are valid (Seedance only documents 480/720, Kling
        // documents 720/1080, Veo uses `resolution` not `mode`). Sending
        // explicit width/height is the one signal that's consistent.
        let parameters: [String: Any] = [
            "prompt": prompt,
            "duration": duration,
            "width": resolution.width,
            "height": resolution.height,
        ]
        let body: [String: Any] = [
            "model": model.rawValue,
            "public": false,
            "parameters": parameters,
        ]
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        req.httpBody = bodyData
        let bodyString = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
        Self.debugLog("POST /v2/generations model=\(model.rawValue) res=\(resolution.rawValue) duration=\(duration)")
        Self.debugLog("  body=\(bodyString)")

        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
            Self.debugLog("start response HTTP \(status) body=\(respBody)")
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let id = Self.extractGenerationId(data: data) else {
                    Self.debugLog("start FAILED to extract generationId")
                    completion(.failure(Self.parseError(data: data, response: response,
                                                         requestBody: bodyString,
                                                         fallback: "Failed to start generation")))
                    return
                }
                Self.debugLog("start ok generationId=\(id)")
                completion(.success(id))
            }
        }.resume()
    }

    private func pollGeneration(id: String, attempt: Int = 0,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        if cancelled { completion(.failure(Self.error("Cancelled"))); return }
        if attempt > 120 { // ~6 minutes at 3s intervals
            completion(.failure(Self.error("Generation timed out")))
            return
        }

        var req = URLRequest(url: v1BaseURL.appendingPathComponent("generations/\(id)"))
        req.setValue("Bearer \(Secrets.leonardoAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let json = Self.json(data) else {
                    Self.debugLog("poll bad response HTTP \(httpStatus) body=\(respBody)")
                    completion(.failure(Self.error("Bad response while polling: \(respBody.prefix(300))")))
                    return
                }
                let gen = (json["generations_by_pk"] as? [String: Any]) ?? [:]
                let status = (gen["status"] as? String) ?? "PENDING"
                Self.debugLog("poll attempt=\(attempt) HTTP \(httpStatus) status=\(status)")
                if status == "COMPLETE" {
                    if let url = Self.extractVideoURL(from: gen) {
                        completion(.success(url))
                    } else {
                        completion(.failure(Self.error("Generation complete but no video URL returned")))
                    }
                    return
                }
                if status == "FAILED" {
                    completion(.failure(Self.error("Leonardo reported the generation failed")))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.pollGeneration(id: id, attempt: attempt + 1, completion: completion)
                }
            }
        }.resume()
    }

    private func downloadVideo(remote: URL, prompt: String,
                               completion: @escaping (Result<URL, Error>) -> Void) {
        let safePrompt = prompt
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined(separator: "")
            .prefix(40)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = outputFolder.appendingPathComponent("\(safePrompt)-\(stamp).mp4")

        URLSession.shared.downloadTask(with: remote) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            // CRITICAL: do the file move synchronously inside this closure.
            // URLSession deletes the temp file the instant the closure
            // returns, so dispatching to main first would leave us trying
            // to move a file that no longer exists.
            if let error = error {
                DispatchQueue.main.async { self.fail(error.localizedDescription, completion) }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.fail("Download finished with no file", completion) }
                return
            }
            // Make sure the Generated/ folder exists in case it was wiped
            // between when generate() created it and now.
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                Self.debugLog("download complete dest=\(dest.path)")
                DispatchQueue.main.async {
                    self.phase = .complete(dest)
                    completion(.success(dest))
                }
            } catch {
                Self.debugLog("download move failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.fail(error.localizedDescription, completion) }
            }
        }.resume()
    }

    // MARK: - Helpers

    private func fail(_ message: String,
                      _ completion: @escaping (Result<URL, Error>) -> Void) {
        phase = .failed(message)
        completion(.failure(Self.error(message)))
    }

    private static func error(_ msg: String) -> Error {
        NSError(domain: "LiveWall.Leonardo", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Append a line to ~/Movies/LiveWall/livewall.log so we have a
    /// single source of truth that's not affected by NSLog's flakiness.
    /// Run `tail -f ~/Movies/LiveWall/livewall.log` to watch live.
    static func debugLog(_ msg: String) {
        NSLog("[LiveWall.Leonardo] \(msg)")
        print("[LiveWall.Leonardo] \(msg)")
        let logURL = (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies"))
            .appendingPathComponent("LiveWall", isDirectory: true)
            .appendingPathComponent("livewall.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        guard let data = data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The v2 video-generation response envelope varies by model. Try
    /// every shape we've seen so the caller doesn't have to care.
    /// Confirmed shape from real Leonardo responses:
    ///   { "generate": { "generationId": "...", "cost": {...} } }
    private static func extractGenerationId(data: Data?) -> String? {
        guard let json = Self.json(data) else { return nil }
        // v2 video models (Kling, Seedance, Veo) use this envelope.
        if let obj = json["generate"] as? [String: Any],
           let id = obj["generationId"] as? String { return id }
        // Top-level fallbacks.
        if let id = json["generationId"] as? String { return id }
        if let id = json["id"] as? String { return id }
        // Legacy image / motion endpoints.
        if let obj = json["sdGenerationJob"] as? [String: Any],
           let id = obj["generationId"] as? String { return id }
        if let obj = json["motionSvdGenerationJob"] as? [String: Any],
           let id = obj["generationId"] as? String { return id }
        if let obj = json["motionVideoGenerationJob"] as? [String: Any],
           let id = obj["generationId"] as? String { return id }
        if let obj = json["generations_image_to_video"] as? [String: Any],
           let id = obj["generationId"] as? String { return id }
        return nil
    }

    /// Pull the finished video URL out of a `generations_by_pk` object.
    /// Different models put the URL in different fields.
    private static func extractVideoURL(from gen: [String: Any]) -> URL? {
        if let videos = gen["generated_videos"] as? [[String: Any]],
           let first = videos.first {
            if let s = first["url"] as? String, let u = URL(string: s) { return u }
            if let s = first["motionMP4URL"] as? String, let u = URL(string: s) { return u }
        }
        if let images = gen["generated_images"] as? [[String: Any]],
           let first = images.first {
            if let s = first["motionMP4URL"] as? String, let u = URL(string: s) { return u }
            if let s = first["url"] as? String, let u = URL(string: s) { return u }
        }
        return nil
    }

    private static func parseError(data: Data?, response: URLResponse?,
                                   requestBody: String = "",
                                   fallback: String) -> Error {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // Always log full detail to the file so we can debug. UI gets a
        // clean short message.
        debugLog("parseError status=\(status) body=\(body.prefix(800))")
        if !requestBody.isEmpty { debugLog("  request body=\(requestBody.prefix(800))") }

        // Try to pull a human-friendly message out of common error shapes.
        if let json = Self.json(data) {
            if let msg = json["error"] as? String { return Self.error(msg) }
            if let msg = json["message"] as? String { return Self.error(msg) }
            // GraphQL-style: { extensions: { details: { errors: [{ message }] } } }
            if let arr = json["errors"] as? [[String: Any]],
               let inner = (arr.first?["extensions"] as? [String: Any])?["details"] as? [String: Any],
               let errs = inner["errors"] as? [[String: Any]],
               let msg = errs.first?["message"] as? String {
                return Self.error(msg)
            }
            if let arr = json["errors"] as? [[String: Any]],
               let msg = arr.first?["message"] as? String {
                return Self.error(msg)
            }
        }
        return Self.error("\(fallback) (HTTP \(status))")
    }
}
