import Foundation
import AppKit

/// Uploads a local image to Leonardo via the documented presigned-URL flow:
///   1. POST /v1/init-image with {extension} → returns presigned URL + fields + ID
///   2. POST multipart/form-data to that URL with the fields and the file
///   3. Caller uses the returned ID as `image.id` (with type=UPLOADED) in
///      a generation request's guidances.start_frame / end_frame.
///
/// The presigned URL expires in two minutes, so steps 1 and 2 must run back
/// to back. A short-lived URL also means we don't hold any reference to it
/// after upload — caller only gets the image ID back.
final class ImageUploadService {

    static let shared = ImageUploadService()

    private let v1BaseURL = URL(string: "https://cloud.leonardo.ai/api/rest/v1")!

    /// 10 MB cap. Leonardo's actual upper bound isn't published but our
    /// presigned URLs reject larger files with a generic S3 error that's
    /// hard to surface usefully. Better to bounce them up front.
    static let maxFileSize: Int = 10 * 1024 * 1024

    private init() {}

    /// Upload a JPEG/PNG file. Completion fires on the main queue with
    /// the Leonardo image ID (use `LeonardoImageRef.uploaded(id:)` to
    /// pass it into generation) or an Error.
    func uploadImage(at fileURL: URL,
                     completion: @escaping (Result<String, Error>) -> Void) {
        // Validate extension up front so we fail fast.
        let ext = fileURL.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "webp"].contains(ext) else {
            return DispatchQueue.main.async {
                completion(.failure(Self.error("Unsupported image type: .\(ext). Use JPG, PNG, or WebP.")))
            }
        }

        // Validate size up front for the same reason.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else {
            return DispatchQueue.main.async {
                completion(.failure(Self.error("Couldn't read \(fileURL.lastPathComponent).")))
            }
        }
        if size > Self.maxFileSize {
            return DispatchQueue.main.async {
                let mb = Double(size) / 1024 / 1024
                completion(.failure(Self.error(String(format: "Image is %.1f MB. Limit is 10 MB.", mb))))
            }
        }

        // Step 1: ask Leonardo for a presigned upload URL.
        requestPresignedURL(extension: ext == "jpeg" ? "jpg" : ext) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let info):
                // Step 2: PUT the bytes to S3.
                self.uploadFile(at: fileURL, to: info) { uploadResult in
                    DispatchQueue.main.async {
                        switch uploadResult {
                        case .failure(let e): completion(.failure(e))
                        case .success:        completion(.success(info.imageId))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 1: presigned URL

    private struct PresignedInfo {
        let url: URL
        let fields: [String: String]
        let imageId: String
    }

    private func requestPresignedURL(extension ext: String,
                                     completion: @escaping (Result<PresignedInfo, Error>) -> Void) {
        var req = URLRequest(url: v1BaseURL.appendingPathComponent("init-image"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.leonardoAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        let body: [String: Any] = ["extension": ext]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        LeonardoService.debugLog("POST /v1/init-image extension=\(ext)")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
            LeonardoService.debugLog("init-image response HTTP \(status) body=\(respBody.prefix(400))")

            if let error = error { return completion(.failure(error)) }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return completion(.failure(Self.error("Bad response from /init-image (HTTP \(status))")))
            }
            // Response shape: { "uploadInitImage": { "id", "fields" (JSON string), "key", "url" } }
            // Older docs show `uploadDatasetImage` — same shape.
            let envelope = (json["uploadInitImage"] as? [String: Any])
                ?? (json["uploadDatasetImage"] as? [String: Any])
            guard let env = envelope,
                  let urlString = env["url"] as? String, let url = URL(string: urlString),
                  let imageId = env["id"] as? String,
                  let fieldsRaw = env["fields"] as? String,
                  let fieldsData = fieldsRaw.data(using: .utf8),
                  let fields = (try? JSONSerialization.jsonObject(with: fieldsData)) as? [String: String]
            else {
                return completion(.failure(Self.error("Couldn't parse presigned-URL response")))
            }
            completion(.success(PresignedInfo(url: url, fields: fields, imageId: imageId)))
        }.resume()
    }

    // MARK: - Step 2: multipart upload to S3

    private func uploadFile(at fileURL: URL,
                            to info: PresignedInfo,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: info.url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var body = Data()
        let crlf = "\r\n"

        // S3 expects the policy fields BEFORE the file part, in order.
        for (key, value) in info.fields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        // The file part itself.
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return completion(.failure(Self.error("Couldn't read \(fileURL.lastPathComponent)")))
        }
        let mime = mimeType(forExtension: fileURL.pathExtension)
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(fileData)
        body.append(crlf.data(using: .utf8)!)

        // Closing boundary.
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        req.httpBody = body

        LeonardoService.debugLog("PUT presigned upload size=\(fileData.count) bytes")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            LeonardoService.debugLog("upload response HTTP \(status)")
            if let error = error { return completion(.failure(error)) }
            // S3 returns 204 (No Content) on success for multipart POST uploads.
            if (200...299).contains(status) {
                return completion(.success(()))
            }
            let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(.failure(Self.error("Upload failed (HTTP \(status)): \(respBody.prefix(300))")))
        }.resume()
    }

    // MARK: - Helpers

    private func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "webp":        return "image/webp"
        default:            return "application/octet-stream"
        }
    }

    private static func error(_ msg: String) -> Error {
        NSError(domain: "LiveWall.ImageUpload", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
