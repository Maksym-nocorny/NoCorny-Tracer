import SwiftUI
import CryptoKit

/// A view that loads and displays a thumbnail from Dropbox for a given path.
struct DropboxThumbnailView: View {
    let path: String
    @Bindable var appState: AppState

    @State private var thumbnail: NSImage?
    @State private var isLoading = false

    // Memory cache
    static var memoryCache = NSCache<NSString, NSImage>()

    /// Paths whose fetch recently failed, with the time of failure. Prevents
    /// `onAppear` from immediately re-firing a doomed network request on every
    /// re-render/scroll. Entries expire after `failedPathTTL`. NSCache is
    /// thread-safe, so this can be touched from the detached fetch Task.
    private static let failedPaths = NSCache<NSString, NSDate>()
    /// How long a path stays "recently failed" before a refetch is allowed
    /// again (covers transient network drops without permanent blanks).
    private static let failedPathTTL: TimeInterval = 60

    /// Disk-cache cap: prune oldest files once we exceed this many bytes.
    private static let diskCacheByteLimit: Int = 50 * 1024 * 1024
    /// Runs the disk-cache prune exactly once per app session.
    private static let pruneOnce: Void = {
        DropboxThumbnailView.pruneDiskCache()
    }()

    /// Disk cache directory for thumbnails
    private static var diskCacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("NoCornyTracer/ThumbnailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()

    var body: some View {
        ZStack {
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.secondary.opacity(0.1))

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(width: 64, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .onAppear {
            loadThumbnail()
        }
    }

    /// Hash the Dropbox path to create a safe filename for disk cache
    private static func cacheFileName(for path: String) -> String {
        let hash = Insecure.MD5.hash(data: Data(path.utf8))
        return hash.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private static func diskCacheURL(for path: String) -> URL {
        diskCacheDirectory.appendingPathComponent(cacheFileName(for: path))
    }

    private func loadThumbnail() {
        // Bound the disk cache once per app session, before heavy list rendering.
        _ = Self.pruneOnce

        let cacheKey = path as NSString

        // 1. Check memory cache
        if let cached = Self.memoryCache.object(forKey: cacheKey) {
            self.thumbnail = cached
            return
        }

        // 2. Check disk cache
        let diskURL = Self.diskCacheURL(for: path)
        if let data = try? Data(contentsOf: diskURL), let img = NSImage(data: data) {
            Self.memoryCache.setObject(img, forKey: cacheKey)
            self.thumbnail = img
            return
        }

        // 2b. Empty-token short-circuit: without a token the network fetch is
        // guaranteed to fail, so leave the placeholder and do NOT spin/sleep/fetch.
        // No failed marker is written here, so signing in lets the next appearance
        // fetch immediately rather than being throttled.
        let token = appState.dropboxAuthManager.accessToken ?? ""
        guard !token.isEmpty else { return }

        // 2c. Negative-result throttle: a token IS present but a recent fetch
        // failed, so skip the refetch until the TTL expires (avoids re-firing a
        // doomed request on every re-render/scroll; transient drops recover after
        // the TTL).
        if let failedAt = Self.failedPaths.object(forKey: cacheKey),
           Date().timeIntervalSince(failedAt as Date) < Self.failedPathTTL {
            return
        }

        guard !isLoading else { return }
        isLoading = true

        // 3. Fetch from network
        Task {
            let delayMs = UInt64.random(in: 0...500)
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

            do {
                let token = await appState.dropboxAuthManager.refreshTokenIfNeeded() ?? appState.dropboxAuthManager.accessToken ?? ""
                let data = try await appState.dropboxUploadManager.getThumbnail(path: path, accessToken: token)
                if let img = NSImage(data: data) {
                    Self.memoryCache.setObject(img, forKey: cacheKey)
                    // Save to disk cache
                    try? data.write(to: diskURL, options: .atomic)
                    await MainActor.run {
                        self.thumbnail = img
                    }
                }
            } catch {
                // Record a negative-result marker so we don't immediately refetch
                // the same doomed path on the next render.
                Self.failedPaths.setObject(NSDate(), forKey: cacheKey)
                print("❌ Thumbnail Error: \(error)")
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }

    /// Prunes the thumbnail disk cache to stay under `diskCacheByteLimit`,
    /// deleting least-recently-modified files first. Runs once per session off
    /// the main thread. Deleting an in-use cache file is harmless (a later
    /// appearance simply refetches it).
    private static func pruneDiskCache() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let dir = diskCacheDirectory
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }

            var files: [(url: URL, size: Int, modified: Date)] = []
            var total = 0
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let size = values.fileSize ?? 0
                let modified = values.contentModificationDate ?? .distantPast
                files.append((url, size, modified))
                total += size
            }

            guard total > diskCacheByteLimit else { return }

            // Oldest first, delete until back under the cap.
            files.sort { $0.modified < $1.modified }
            for file in files {
                if total <= diskCacheByteLimit { break }
                try? fm.removeItem(at: file.url)
                total -= file.size
            }
        }
    }
}
