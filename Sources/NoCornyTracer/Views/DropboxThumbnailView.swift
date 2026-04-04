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
                print("❌ Thumbnail Error: \(error)")
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
