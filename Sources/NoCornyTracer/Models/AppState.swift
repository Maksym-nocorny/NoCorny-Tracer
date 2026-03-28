import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// Central app state managing all sub-managers and user preferences
@Observable
final class AppState {
    // MARK: - Managers
    let recordingManager = RecordingManager()
    let dropboxAuthManager = DropboxAuthManager()
    let dropboxUploadManager = DropboxUploadManager()
    let aiNamingService = AINamingService()
    let hotkeyManager = HotkeyManager()
    let cameraManager = CameraManager()

    // MARK: - State
    var recordings: [Recording] = []
    var dropboxUsedSpace: UInt64 = 0
    var dropboxAllocatedSpace: UInt64 = 0
    var isSyncingDropbox: Bool = false
    
    var showSettings = false
    var selectedMicrophoneID: String?
    var isMicrophoneEnabled: Bool = true
    var autoUploadEnabled: Bool = true
    var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    var videoResolution: VideoResolution = .hd1080 {
        didSet {
            UserDefaults.standard.set(videoResolution.rawValue, forKey: "videoResolution")
        }
    }
    var videoFrameRate: VideoFrameRate = .fps30 {
        didSet {
            UserDefaults.standard.set(videoFrameRate.rawValue, forKey: "videoFrameRate")
        }
    }
    
    // MARK: - Camera Preferences
    var isCameraEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isCameraEnabled, forKey: "isCameraEnabled")
            updateCameraState()
        }
    }
    var selectedCameraDeviceID: String? {
        didSet {
            UserDefaults.standard.set(selectedCameraDeviceID, forKey: "selectedCameraDeviceID")
            cameraManager.selectedDeviceID = selectedCameraDeviceID
        }
    }

    // MARK: - Persistence Keys
    private let recordingsKey = "savedRecordings"
    private static let hasLaunchedBeforeKey = "hasLaunchedBefore"

    /// Set to true on first launch to show a dialog asking about launch at login
    var showLaunchAtLoginPrompt = false

    init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.isCameraEnabled = UserDefaults.standard.bool(forKey: "isCameraEnabled")
        self.selectedCameraDeviceID = UserDefaults.standard.string(forKey: "selectedCameraDeviceID")
        if let resRaw = UserDefaults.standard.string(forKey: "videoResolution"),
           let res = VideoResolution(rawValue: resRaw) {
            self.videoResolution = res
        }
        if let fpsRaw = UserDefaults.standard.object(forKey: "videoFrameRate") as? Int,
           let fps = VideoFrameRate(rawValue: fpsRaw) {
            self.videoFrameRate = fps
        }
        
        loadRecordings()
        // Ensure system state matches our stored preference
        updateLaunchAtLogin()
        // Check if this is the first launch
        checkFirstLaunch()
        // Start global hotkeys (temporarily disabled for debugging)
        // hotkeyManager.start(appState: self)
        
        // Setup initial camera state
        cameraManager.isEnabled = self.isCameraEnabled
        if let id = self.selectedCameraDeviceID {
            cameraManager.selectedDeviceID = id
        } else {
            // Restore newly selected device ID from discovery to AppState
            self.selectedCameraDeviceID = cameraManager.selectedDeviceID
        }
        updateCameraState()
    }

    private func checkFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
            showLaunchAtLoginPrompt = true
        }
    }

    // MARK: - Launch at Login
    func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                    print("⚙️ Startup: Registered for launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    print("⚙️ Startup: Unregistered launch at login")
                }
            }
        } catch {
            print("⚙️ Startup: Failed to update launch at login: \(error)")
        }
    }
    
    // MARK: - Camera State
    private func updateCameraState() {
        cameraManager.isEnabled = isCameraEnabled
        
        if isCameraEnabled {
            Task { await cameraManager.startSession() }
        } else {
            cameraManager.stopSession()
        }
    }

    // MARK: - Recording Lifecycle

    func startRecording() async throws {
        // Wait 0.5 seconds to allow UI/popovers to completely hide before recording starts
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        try await recordingManager.startRecording(
            microphoneEnabled: isMicrophoneEnabled,
            microphoneDeviceID: selectedMicrophoneID,
            videoWidth: videoResolution.width,
            videoHeight: videoResolution.height,
            fps: videoFrameRate.rawValue
        )
    }

    /// Abort recording: stops and discards the file without saving or uploading
    func abortRecording() async {
        guard let recording = await recordingManager.stopRecording() else { return }
        // Delete the local file immediately
        try? FileManager.default.removeItem(at: recording.fileURL)
        print("🗑️ Recording aborted and file deleted")
    }

    func stopRecording() async {
        guard let recording = await recordingManager.stopRecording() else { return }
        let newRecording = recording

        recordings.insert(newRecording, at: 0)
        saveRecordings()

        // Process everything in the background (non-blocking)
        let recordingID = newRecording.id
        Task { await self.processRecording(id: recordingID) }
    }

    /// Background processing: upload → shared link → subtitles → AI name → rename → cleanup
    private func processRecording(id: UUID) async {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let fileURL = recordings[index].fileURL

        // Step 1: Upload to Dropbox immediately with default timestamp name
        var dropboxPath: String?
        var token = ""

        if autoUploadEnabled && dropboxAuthManager.isSignedIn {
            recordings[index].uploadStatus = .uploading
            saveRecordings()

            do {
                token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""

                let uploadedPath = try await dropboxUploadManager.upload(
                    fileURL: fileURL,
                    fileName: recordings[index].displayName + ".mp4",
                    accessToken: token
                )

                if let idx = recordings.firstIndex(where: { $0.id == id }) {
                    recordings[idx].dropboxPath = uploadedPath
                    recordings[idx].uploadStatus = .uploaded
                    dropboxPath = uploadedPath
                    saveRecordings()
                    print("📤 Upload: ✅ Uploaded to Dropbox: \(uploadedPath)")
                }

                // Create shared link immediately after upload
                let sharedURL = try await dropboxUploadManager.createSharedLink(
                    path: uploadedPath,
                    accessToken: token
                )
                if let idx = recordings.firstIndex(where: { $0.id == id }) {
                    recordings[idx].dropboxSharedURL = sharedURL
                    saveRecordings()
                    print("🔗 Shared link: ✅ \(sharedURL)")
                }
            } catch {
                if let idx = recordings.firstIndex(where: { $0.id == id }) {
                    recordings[idx].uploadStatus = .failed
                    print("📤 Upload: ❌ \(error)")
                    saveRecordings()
                }
            }
        }

        // Step 2: Generate and upload subtitles
        print("🤖 Starting subtitle generation...")
        var generatedSubtitles: String? = nil
        
        if let subtitles = await aiNamingService.generateSubtitles(for: fileURL) {
            generatedSubtitles = subtitles
            if let idx = recordings.firstIndex(where: { $0.id == id }),
               !token.isEmpty {
                let srtFileName = recordings[idx].displayName + ".srt"
                do {
                    let srtPath = try await dropboxUploadManager.uploadTextFile(
                        content: subtitles,
                        fileName: srtFileName,
                        accessToken: token
                    )
                    print("📤 Subtitles: ✅ Uploaded as \"\(srtFileName)\" (path: \(srtPath))")
                } catch {
                    print("📤 Subtitles: ❌ Upload failed: \(error)")
                }
            }
        }

        // Step 3: AI Naming (using frames + subtitles)
        print("🤖 Starting AI naming...")
        if let aiNameBase = await aiNamingService.generateName(for: fileURL, subtitles: generatedSubtitles) {
            if let idx = recordings.firstIndex(where: { $0.id == id }) {
                let formatter = DateFormatter()
                formatter.dateFormat = "dd MMMM yyyy - HH.mm"
                let dateString = formatter.string(from: recordings[idx].createdAt)
                let aiName = "\(aiNameBase) \(dateString)"
                
                recordings[idx].aiGeneratedName = aiName
                saveRecordings()
                print("🤖 AI Naming: ✅ Named: \"\(aiName)\"")

                // Step 4: Rename on Dropbox if uploaded
                if let currentPath = dropboxPath, !token.isEmpty {
                    do {
                        let newPath = try await dropboxUploadManager.renameFile(
                            fromPath: currentPath,
                            toNewName: aiName + ".mp4",
                            accessToken: token
                        )
                        recordings[idx].dropboxPath = newPath
                        saveRecordings()
                        print("📤 Rename: ✅ Renamed on Dropbox to \"\(aiName).mp4\"")
                        
                        // Automatically open the Dropbox link in the browser
                        if let url = recordings[idx].shareURL {
                            DispatchQueue.main.async {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } catch {
                        print("📤 Rename: ❌ \(error)")
                    }
                }
            }
        }

        // Step 5: Delete local file after everything is done
        if dropboxPath != nil {
            try? FileManager.default.removeItem(at: fileURL)
            print("🗑️ Local file deleted")
            
            // Step 6: Sync Dropbox state to update UI
            await syncDropboxState()
        }
    }

    // MARK: - Dropbox Sync

    @MainActor
    func syncDropboxState() async {
        guard dropboxAuthManager.isSignedIn else { return }
        isSyncingDropbox = true
        defer { isSyncingDropbox = false }
        
        guard let token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken else { return }
        
        do {
            // 1. Storage
            let space = try await dropboxUploadManager.getSpaceUsage(accessToken: token)
            self.dropboxUsedSpace = space.used
            self.dropboxAllocatedSpace = space.allocated
            
            // 2. Fetch list & links
            async let filesTask = dropboxUploadManager.listFolder(path: "/NoCorny Tracer", accessToken: token)
            async let linksTask = dropboxUploadManager.listAllSharedLinks(accessToken: token)
            
            let files = try await filesTask
            let links = try await linksTask
            
            // 3. Process into Recordings
            var syncedRecordings: [Recording] = []
            let df = ISO8601DateFormatter()
            
            for file in files {
                let lowerPath = file.pathDisplay.lowercased()
                let sharedUrl = links[lowerPath]
                let date = df.date(from: file.clientModified) ?? Date()
                
                var existingID = UUID()
                if let matched = self.recordings.first(where: { $0.dropboxPath?.lowercased() == lowerPath }) {
                    existingID = matched.id
                }
                
                let fakeURL = URL(fileURLWithPath: "/tmp/\(file.name)")
                var rec = Recording(id: existingID, fileURL: fakeURL, createdAt: date, duration: 0, uploadStatus: .uploaded)
                rec.dropboxPath = file.pathDisplay
                rec.dropboxSharedURL = sharedUrl
                
                let baseName = (file.name as NSString).deletingPathExtension
                if !baseName.starts(with: "Recording_") {
                    rec.aiGeneratedName = baseName
                }
                
                syncedRecordings.append(rec)
            }
            
            // Sort synced by date descending
            syncedRecordings.sort { $0.createdAt > $1.createdAt }
            
            // 4. Merge with local active ones (e.g. uploading/failed)
            let activeLocal = self.recordings.filter { $0.uploadStatus != .uploaded && $0.uploadStatus != .notUploaded }
            self.recordings = activeLocal + syncedRecordings
            
            saveRecordings()
            
        } catch {
            print("❌ Dropbox Sync Failed: \(error)")
        }
    }

    // MARK: - Persistence

    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: recordingsKey)
        }
    }

    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: recordingsKey),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        recordings = decoded
    }

    // MARK: - History Management

    func clearHistory() {
        recordings.removeAll()
        saveRecordings()
    }

    // MARK: - Recordings Directory

    static var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
