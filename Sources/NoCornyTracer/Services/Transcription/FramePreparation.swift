import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO

/// Video-frame sampling for the multimodal calls: pick representative stills, drop
/// near-duplicates, and squeeze the survivors under a byte budget.
///
/// Separate from AudioPreparation because this is the only part of the pipeline that
/// needs AppKit and ImageIO, and because engines differ in whether they want frames at
/// all -- a local Whisper run wants none, so this work should not sit on the path
/// everybody walks.
enum FramePreparation {

    /// Extracts frames at evenly spaced timestamps. 1024×1024 max resolution: still readable
    /// for code/UI screenshots, ~55% fewer image tokens than 1568.
    static func extractFrames(from videoURL: URL) async -> [Data] {
        let asset = AVAsset(url: videoURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        guard durationSeconds > 0 else { return [] }

        let timestamps = pickTimestamps(duration: durationSeconds)
        guard !timestamps.isEmpty else { return [] }
        LogManager.shared.log("🤖 AI Naming: Picked \(timestamps.count) timestamps: \(timestamps.map { String(format: "%.1f", $0) }.joined(separator: ", "))s")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let times: [NSValue] = timestamps.map { ts in
            NSValue(time: CMTime(seconds: ts, preferredTimescale: 600))
        }

        let timesCount = times.count
        let rendered: [(timestamp: Double, data: Data)] = await withCheckedContinuation { continuation in
            var results: [(Double, Data)] = []
            var processedCount = 0
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, actualTime, result, error in
                if result == .succeeded, let cgImage = image {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        let ts = CMTimeGetSeconds(requestedTime)
                        lock.lock()
                        results.append((ts, jpegData))
                        lock.unlock()
                    }
                }

                lock.lock()
                processedCount += 1
                let done = processedCount == timesCount
                lock.unlock()

                if done {
                    let sorted = results.sorted { $0.0 < $1.0 }
                    continuation.resume(returning: sorted.map { (timestamp: $0.0, data: $0.1) })
                }
            }
        }

        let deduped = deduplicate(frames: rendered, hammingThreshold: 5)
        if deduped.count != rendered.count {
            LogManager.shared.log("🤖 AI Naming: Deduped \(rendered.count) → \(deduped.count) frames")
        }
        return deduped
    }

    /// Base64 inflates raw bytes by 4/3 (ceil division). Every size check against the request
    /// budget must use the ENCODED size — guarding on raw bytes is what let a 6.2 MB body
    /// sail past an 18 MB "limit" and die at the proxy.
    static func base64Size(_ rawBytes: Int) -> Int { (rawBytes + 2) / 3 * 4 }

    static func encodedSize(_ frames: [Data]) -> Int {
        frames.reduce(0) { $0 + base64Size($1.count) }
    }

    /// Degradation ladder for oversized frame sets, cheapest-first.
    ///
    /// Quality steps come before downscaling on purpose: Gemini bills images by pixel
    /// dimensions, not bytes, so dropping JPEG quality shrinks the request for free while
    /// downscaling actually costs visual detail (and 1024px was already chosen as the
    /// readability floor for code/UI screenshots). Dropping frames comes last.
    static let frameBudgetLadder: [FrameBudgetStep] = [
        FrameBudgetStep(quality: 0.60, maxEdge: nil, keep: nil),
        FrameBudgetStep(quality: 0.45, maxEdge: nil, keep: nil),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: nil),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: 6),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: 3),
        FrameBudgetStep(quality: 0.55, maxEdge: 640, keep: 1),
    ]

    /// Shrinks `frames` until their base64 total fits `budget`, returning [] if even one
    /// downscaled frame won't fit. Text-heavy screen content is the worst case for JPEG, and
    /// 10 such frames at 1024px/q0.85 can exceed the entire request budget on their own —
    /// so this runs on every path that sends frames, including the image-only fallback.
    static func fitFramesToBudget(_ frames: [Data], budget: Int) -> [Data] {
        guard !frames.isEmpty, budget > 0 else { return [] }
        let original = encodedSize(frames)
        if original <= budget { return frames }

        for step in Self.frameBudgetLadder {
            var candidate = frames
            if let keep = step.keep, keep < candidate.count {
                candidate = evenlySampled(candidate, keep: keep)
            }
            candidate = candidate.map { reencodeJPEG($0, quality: step.quality, maxEdge: step.maxEdge) ?? $0 }
            let size = encodedSize(candidate)
            if size <= budget {
                LogManager.shared.log(
                    "🤖 Frames: fitted \(original / 1024)KB → \(size / 1024)KB b64 (q\(step.quality), edge=\(step.maxEdge.map(String.init) ?? "orig"), \(candidate.count)/\(frames.count) frames)"
                )
                return candidate
            }
        }

        LogManager.shared.log(
            "🤖 Frames: ⚠️ \(original / 1024)KB b64 won't fit \(budget / 1024)KB budget even at minimum quality — dropping frames",
            type: .error
        )
        return []
    }

    /// Picks `keep` frames spread evenly across the set so the sample still spans the whole
    /// recording rather than clustering at the start.
    static func evenlySampled(_ frames: [Data], keep: Int) -> [Data] {
        guard keep > 0, keep < frames.count else { return frames }
        if keep == 1 { return [frames[frames.count / 2]] }
        let step = Double(frames.count - 1) / Double(keep - 1)
        var picked: [Data] = []
        var seen = Set<Int>()
        for i in 0..<keep {
            let idx = min(frames.count - 1, Int((Double(i) * step).rounded()))
            if seen.insert(idx).inserted { picked.append(frames[idx]) }
        }
        return picked
    }

    /// Re-encodes a JPEG at `quality`, optionally downscaling the longest edge to `maxEdge`
    /// first. Returns nil when the image can't be decoded or re-encoded — callers keep the
    /// original frame in that case, so a failure here can only cost budget, never correctness.
    static func reencodeJPEG(_ data: Data, quality: Double, maxEdge: Int?) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        var rep = source

        if let maxEdge, max(source.pixelsWide, source.pixelsHigh) > maxEdge {
            let scale = Double(maxEdge) / Double(max(source.pixelsWide, source.pixelsHigh))
            let width = max(1, Int((Double(source.pixelsWide) * scale).rounded()))
            let height = max(1, Int((Double(source.pixelsHigh) * scale).rounded()))
            guard let scaled = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 3,
                hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            scaled.size = NSSize(width: width, height: height)

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            rep = scaled
        }

        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func pickTimestamps(duration: Double) -> [Double] {
        guard duration > 0 else { return [] }

        if duration < 1 {
            return [duration / 2]
        }

        let n = max(3, min(10, Int(ceil(duration / 10.0))))
        let interval = duration / Double(n)
        var equispaced = (0..<n).map { interval * Double($0) + (interval / 2) }
        if !equispaced.isEmpty {
            equispaced[0] = min(equispaced[0], 0.5)
        }

        return equispaced
    }

    static func deduplicate(frames: [(timestamp: Double, data: Data)], hammingThreshold: Int) -> [Data] {
        guard !frames.isEmpty else { return [] }

        var accepted: [(timestamp: Double, data: Data, hash: UInt64?)] = []
        var rejected: [(timestamp: Double, data: Data)] = []

        for frame in frames {
            let hash = dHash(frame.data)
            let isDup = accepted.contains { existing in
                guard let h1 = hash, let h2 = existing.hash else { return false }
                return hammingDistance(h1, h2) < hammingThreshold
            }
            if isDup {
                rejected.append((frame.timestamp, frame.data))
            } else {
                accepted.append((frame.timestamp, frame.data, hash))
            }
        }

        let minFrames = min(3, frames.count)
        while accepted.count < minFrames && !rejected.isEmpty {
            let restored = rejected.removeFirst()
            accepted.append((restored.timestamp, restored.data, nil))
        }

        return accepted.sorted { $0.timestamp < $1.timestamp }.map { $0.data }
    }

    static func dHash(_ jpegData: Data) -> UInt64? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = 9
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixels = context.data else { return nil }
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left = buffer[y * width + x]
                let right = buffer[y * width + x + 1]
                if left > right {
                    hash |= (UInt64(1) << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }
}
