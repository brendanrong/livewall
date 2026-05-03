import Cocoa
import AVFoundation

/// Pulls a single frame out of a video file for use as a preview thumbnail.
enum VideoThumbnail {

    /// Async — invokes `completion` on the main thread.
    static func generate(for url: URL, size: NSSize,
                         completion: @escaping (NSImage?) -> Void) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Render a bit larger than display size for retina sharpness.
        gen.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        // Grab a frame ~1s in (avoids black opening frames in many videos).
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { cg, _, error in
            let img: NSImage?
            if let cg = cg, error == nil {
                img = NSImage(cgImage: cg, size: size)
            } else {
                img = nil
            }
            DispatchQueue.main.async { completion(img) }
        }
    }
}
