import AppKit
import Foundation

/// Disk-backed avatar cache keyed by source URL.
///
/// Why: `AsyncImage` re-downloads the avatar every time Settings opens, which is wasteful
/// and causes a visible flash. We cache the JPG on disk plus ETag / Last-Modified headers,
/// so subsequent loads are instant — and once a day we revalidate with a conditional GET.
@MainActor
@Observable
final class AvatarCache {
    static let shared = AvatarCache()

    var image: NSImage?

    private struct Meta: Codable {
        var url: String
        var etag: String?
        var lastModified: String?
        var fetchedAt: Date
    }

    private var meta: Meta?
    /// In-flight fetch, so sign-out can cancel it and we don't start duplicates.
    private var fetchTask: Task<Void, Never>?
    private let cacheDir: URL
    private var metaFile: URL { cacheDir.appendingPathComponent("avatar.meta.json") }
    private var imageFile: URL { cacheDir.appendingPathComponent("avatar.jpg") }
    private let revalidateInterval: TimeInterval = 86_400

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = caches.appendingPathComponent("NoCornyTracer", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: metaFile),
           let decoded = try? JSONDecoder().decode(Meta.self, from: data) {
            meta = decoded
            image = NSImage(contentsOf: imageFile)
        }
    }

    func ensure(urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else {
            if meta != nil { clear() }
            return
        }

        if let m = meta, m.url == urlString, image != nil,
           Date().timeIntervalSince(m.fetchedAt) < revalidateInterval {
            return
        }

        if meta?.url != urlString {
            // URL changed — drop stale image so the avatar slot shows a fallback until the new one loads.
            image = nil
        }

        // De-duplicate: don't stack a second fetch on top of one already running.
        guard fetchTask == nil else { return }
        fetchTask = Task { [weak self] in
            await self?.fetch(urlString: urlString, url: url)
            self?.fetchTask = nil
        }
    }

    func clear() {
        // Cancel any in-flight fetch so it can't complete after sign-out and
        // re-persist the previous user's avatar.
        fetchTask?.cancel()
        fetchTask = nil
        meta = nil
        image = nil
        try? FileManager.default.removeItem(at: metaFile)
        try? FileManager.default.removeItem(at: imageFile)
    }

    private func fetch(urlString: String, url: URL) async {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        // Only send a conditional GET when we actually have the cached image to
        // revalidate; otherwise a 304 would leave the avatar permanently blank.
        if meta?.url == urlString, image != nil {
            if let etag = meta?.etag { req.addValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = meta?.lastModified { req.addValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else {
            return
        }

        // Sign-out (or a new fetch) happened while we were awaiting — discard.
        guard !Task.isCancelled else { return }

        if http.statusCode == 304 {
            // Not modified — bump fetchedAt so we don't revalidate on every open.
            if var m = meta, m.url == urlString {
                m.fetchedAt = Date()
                meta = m
                persistMeta()
            }
            return
        }

        guard http.statusCode == 200, let img = NSImage(data: data) else { return }

        try? data.write(to: imageFile, options: .atomic)
        meta = Meta(
            url: urlString,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            fetchedAt: Date()
        )
        persistMeta()
        image = img
    }

    private func persistMeta() {
        guard let meta, let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaFile, options: .atomic)
    }
}
