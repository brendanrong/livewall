import Foundation

// MARK: - Models / resolutions exposed in the UI

/// One of the three video models the user can pick in the Generate pane.
/// Each carries its own duration list and supported resolutions because
/// the underlying Leonardo models all have different constraints.
enum LeonardoModel: String, CaseIterable {
    // Models on the v2 unified generations endpoint.
    case kling30        = "kling-3.0"
    case seedance20Fast = "seedance-2.0-fast"
    case ltxv23Pro      = "ltxv-2.3-pro"
    // Veo runs on the older v1 generations-image-to-video / -text-to-video
    // endpoints, with a different body shape (imageId/imageType +
    // resolution enum, not guidances + width/height). The v1 model enum
    // maxes out at Veo 3 right now; Veo 3.1 isn't in the public API yet.
    case veo3Fast       = "VEO3FAST"

    var displayName: String {
        switch self {
        case .kling30:        return "Kling 3.0"
        case .seedance20Fast: return "Seedance 2.0 Fast"
        case .ltxv23Pro:      return "LTX 2.3 Pro"
        case .veo3Fast:       return "Veo 3 Fast"
        }
    }

    /// True if this model uses the v1 generations-image-to-video /
    /// generations-text-to-video endpoint family. False means v2.
    var usesV1Endpoint: Bool {
        switch self {
        case .veo3Fast: return true
        default:        return false
        }
    }

    /// Allowed durations in seconds, ordered as we want them to appear.
    var durations: [Int] {
        switch self {
        case .kling30:        return [3, 5, 7, 10, 15]
        case .seedance20Fast: return [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        case .ltxv23Pro:      return [6, 8, 10]
        case .veo3Fast:       return [4, 6, 8]   // per Leonardo docs
        }
    }

    var defaultDuration: Int {
        switch self {
        case .kling30:        return 5
        case .seedance20Fast: return 8
        case .ltxv23Pro:      return 8
        case .veo3Fast:       return 8
        }
    }

    /// Resolutions the model supports. Order = order shown in the dropdown.
    /// LTX 2.3 Pro tops out at 1440p. Veo 3 Fast is 1080p only.
    var resolutions: [LeonardoResolution] {
        switch self {
        case .kling30:        return [.fullHD]
        case .seedance20Fast: return [.fullHD]
        case .ltxv23Pro:      return [.fullHD, .qhd1440]
        case .veo3Fast:       return [.fullHD]
        }
    }

    var defaultResolution: LeonardoResolution {
        switch self {
        case .ltxv23Pro: return .qhd1440
        default:         return .fullHD
        }
    }

    /// Whether this model supports an optional start-frame image.
    var supportsStartFrame: Bool {
        // All four currently allow guidances.start_frame per docs.
        return true
    }

    /// Whether this model supports an optional end frame (transition video).
    /// End frame requires start frame to also be set.
    var supportsEndFrame: Bool {
        // Kling, Seedance, Veo, and LTX all document end_frame.
        return true
    }

    /// Rough wall-clock time we expect a generation to take, in seconds.
    /// Used by the progress bar to give the user a sense of pacing.
    func expectedSeconds(forClipDuration duration: Int) -> TimeInterval {
        let base: TimeInterval
        switch self {
        case .kling30:        base = 180  // 3 min for 5s
        case .seedance20Fast: base = 90   // 1.5 min for 8s
        case .ltxv23Pro:      base = 200  // ~3.3 min for 8s at 1440p
        case .veo3Fast:       base = 120  // ~2 min for 8s
        }
        let scale = 1.0 + Double(max(duration, 1) - 5) * 0.04
        return base * scale
    }

    /// Rough cost estimate in USD for the given parameters. Numbers come
    /// from observed `cost.amount` values in real generation responses,
    /// extrapolated. Always shown to the user with a "~" prefix because
    /// these are estimates, not contracts.
    func estimatedCostUSD(resolution: LeonardoResolution,
                          duration: Int,
                          hasStartFrame: Bool,
                          hasEndFrame: Bool) -> Double {
        // Per-second base rate at 1080p, in USD.
        let baseRatePerSecond: Double
        switch self {
        case .kling30:        baseRatePerSecond = 0.17  // ~$0.84 for 5s
        case .seedance20Fast: baseRatePerSecond = 0.36  // ~$1.81 for 5s
        case .ltxv23Pro:      baseRatePerSecond = 0.45  // estimated
        case .veo3Fast:       baseRatePerSecond = 0.30  // estimated
        }
        // Resolution multiplier — pixel count scales roughly with cost.
        let resMultiplier: Double
        switch resolution {
        case .fullHD:  resMultiplier = 1.0
        case .qhd1440: resMultiplier = 1.6   // ~1.78x pixels
        case .uhd4K:   resMultiplier = 3.5   // ~4x pixels but Leonardo discounts a bit
        }
        // Image-to-video typically a small premium on top.
        let frameMultiplier = (hasStartFrame || hasEndFrame) ? 1.10 : 1.0
        return baseRatePerSecond * Double(duration) * resMultiplier * frameMultiplier
    }
}

/// 16:9 video output sizes we expose.
enum LeonardoResolution: String, CaseIterable {
    case fullHD  = "RESOLUTION_1080" // 1920x1080
    case qhd1440 = "RESOLUTION_1440" // 2560x1440
    case uhd4K   = "RESOLUTION_2160" // 3840x2160

    var displayName: String {
        switch self {
        case .fullHD:  return "1080p"
        case .qhd1440: return "1440p"
        case .uhd4K:   return "4K"
        }
    }

    var width: Int {
        switch self {
        case .fullHD:  return 1920
        case .qhd1440: return 2560
        case .uhd4K:   return 3840
        }
    }

    var height: Int {
        switch self {
        case .fullHD:  return 1080
        case .qhd1440: return 1440
        case .uhd4K:   return 2160
        }
    }
}

/// Reference to an image already uploaded to Leonardo via the presigned-URL
/// init-image flow. Pass instances of these into `LeonardoService.generate`
/// as the `startFrame` and/or `endFrame` parameters.
struct LeonardoImageRef: Equatable {
    /// The init-image ID returned by Leonardo. Used as `image.id` in
    /// guidances.start_frame / end_frame.
    let id: String
    /// Always "UPLOADED" for user-supplied init images. The other valid
    /// value is "GENERATED" (when chaining off a previously generated
    /// image), which we don't currently produce.
    let type: String

    static func uploaded(id: String) -> LeonardoImageRef {
        LeonardoImageRef(id: id, type: "UPLOADED")
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
    ///
    /// Optional `startFrame` / `endFrame` make this an image-to-video
    /// generation. End frame requires start frame; if you violate that
    /// constraint Leonardo will reject the request.
    func generate(prompt: String,
                  model: LeonardoModel,
                  resolution: LeonardoResolution,
                  duration: Int,
                  startFrame: LeonardoImageRef? = nil,
                  endFrame: LeonardoImageRef? = nil,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        cancelled = false
        phase = .starting
        try? FileManager.default.createDirectory(
            at: outputFolder, withIntermediateDirectories: true)

        startGeneration(prompt: prompt, model: model,
                        resolution: resolution, duration: duration,
                        startFrame: startFrame, endFrame: endFrame) { [weak self] result in
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
                                 startFrame: LeonardoImageRef?,
                                 endFrame: LeonardoImageRef?,
                                 completion: @escaping (Result<String, Error>) -> Void) {

        // Per-model: pick the endpoint, build the body. Veo runs on the
        // older v1 generations-image-to-video / generations-text-to-video
        // endpoints with their own body shape. Everything else uses the
        // unified v2 endpoint.
        let url: URL
        let body: [String: Any]

        if model.usesV1Endpoint {
            // v1 image-to-video / text-to-video. Picks the right path
            // based on whether we have a start frame. Body uses
            // imageId/imageType + resolution enum (RESOLUTION_1080), no
            // guidances, no width/height. End frame is only supported on
            // kling2_1 per docs, so we drop it for Veo.
            let path = (startFrame != nil) ? "generations-image-to-video" : "generations-text-to-video"
            url = v1BaseURL.appendingPathComponent(path)

            var params: [String: Any] = [
                "prompt": prompt,
                "model": model.rawValue,
                "duration": duration,
                "resolution": resolution.rawValue,
                "isPublic": false,
            ]
            if let sf = startFrame {
                params["imageId"] = sf.id
                params["imageType"] = sf.type
            }
            body = params
        } else {
            // v2 unified endpoint.
            url = v2BaseURL.appendingPathComponent("generations")

            var guidances: [String: Any] = [:]
            if let sf = startFrame {
                guidances["start_frame"] = [["image": ["id": sf.id, "type": sf.type]]]
            }
            if let ef = endFrame {
                guidances["end_frame"] = [["image": ["id": ef.id, "type": ef.type]]]
            }

            switch model {
            case .ltxv23Pro:
                // 1080p / 1440p: top-level envelope, real dimensions,
                // full LTX param set. prompt_enhance must be OFF when a
                // start_frame is set or LTX returns VALIDATION_ERROR.
                var params: [String: Any] = [
                    "prompt": prompt,
                    "duration": duration,
                    "width": resolution.width,
                    "height": resolution.height,
                    "mode": resolution.rawValue,
                    "audio": false,
                    "quantity": 1,
                    "prompt_enhance": (startFrame == nil) ? "AUTO" : "OFF",
                ]
                if !guidances.isEmpty { params["guidances"] = guidances }
                body = [
                    "model": model.rawValue,
                    "public": false,
                    "parameters": params,
                ]
            case .kling30, .seedance20Fast:
                // Plain top-level envelope. width/height set the preset.
                var params: [String: Any] = [
                    "prompt": prompt,
                    "duration": duration,
                    "width": resolution.width,
                    "height": resolution.height,
                ]
                if !guidances.isEmpty { params["guidances"] = guidances }
                body = [
                    "model": model.rawValue,
                    "public": false,
                    "parameters": params,
                ]
            case .veo3Fast:
                // Unreachable — handled by the v1 branch above.
                fatalError("veo3Fast should route through usesV1Endpoint")
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.leonardoAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        req.httpBody = bodyData
        let bodyString = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
        Self.debugLog("POST \(url.path) model=\(model.rawValue) res=\(resolution.rawValue) duration=\(duration) startFrame=\(startFrame?.id ?? "-") endFrame=\(endFrame?.id ?? "-")")
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
                    // Try to surface a specific reason if the response
                    // gave us one. Otherwise show a generic message and
                    // log the full gen object for diagnostics.
                    let reason = (gen["failureReason"] as? String)
                        ?? (gen["errorMessage"] as? String)
                        ?? (gen["error"] as? String)
                    Self.debugLog("poll FAILED gen=\(gen)")
                    if let reason = reason, !reason.isEmpty {
                        completion(.failure(Self.error("Generation failed: \(reason)")))
                    } else {
                        completion(.failure(Self.error("Generation failed on the server")))
                    }
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
