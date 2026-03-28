import SwiftUI

/// A view that loads and displays a thumbnail from Dropbox for a given path.
struct DropboxThumbnailView: View {
    let path: String
    @Bindable var appState: AppState
    
    @State private var thumbnail: NSImage?
    @State private var isLoading = false
    
    // Simple memory cache
    static var cache = NSCache<NSString, NSImage>()
    
    var body: some View {
        ZStack {
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
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
        .frame(width: 48, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        let cacheKey = path as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            self.thumbnail = cached
            return
        }
        
        guard !isLoading else { return }
        isLoading = true
        
        Task {
            do {
                let token = await appState.dropboxAuthManager.refreshTokenIfNeeded() ?? appState.dropboxAuthManager.accessToken ?? ""
                let data = try await appState.dropboxUploadManager.getThumbnail(path: path, accessToken: token)
                if let img = NSImage(data: data) {
                    Self.cache.setObject(img, forKey: cacheKey)
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
