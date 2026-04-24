import Foundation
import AVFoundation
import AppKit

/// Generates a JPG thumbnail from a local video file.
enum ThumbnailGenerator {

    enum ThumbnailError: LocalizedError {
        case cannotLoadDuration
        case cannotGenerateFrame
        case cannotEncodeJPG
        case cannotWriteFile

        var errorDescription: String? {
            switch self {
            case .cannotLoadDuration:   return "Could not read video duration"
            case .cannotGenerateFrame:  return "Could not extract a frame from the video"
            case .cannotEncodeJPG:      return "Could not encode thumbnail as JPG"
            case .cannotWriteFile:      return "Could not write thumbnail to disk"
            }
        }
    }

    /// Extracts a frame at ~10% into the video (but no earlier than 0.5s), encodes to JPG,
    /// writes to a temp file, and returns its URL. Caller should delete the temp file
    /// after uploading.
    static func generateJPG(from videoURL: URL, maxWidth: CGFloat = 1280) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        let duration: CMTime
        if #available(macOS 13.0, *) {
            duration = try await asset.load(.duration)
        } else {
            duration = asset.duration
        }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw ThumbnailError.cannotLoadDuration
        }
        let targetSeconds = max(0.5, seconds * 0.1)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 9 / 16)

        let cgImage: CGImage
        if #available(macOS 13.0, *) {
            cgImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: targetTime)]) { _, image, _, _, error in
                    if let image = image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? ThumbnailError.cannotGenerateFrame)
                    }
                }
            }
        } else {
            cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ThumbnailError.cannotEncodeJPG
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-thumb-\(UUID().uuidString).jpg")
        do {
            try jpgData.write(to: tempURL, options: .atomic)
        } catch {
            throw ThumbnailError.cannotWriteFile
        }
        return tempURL
    }
}
