import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import Sparkle

@Observable
final class PermissionsManager {
    // Current permission status
    var isScreenRecordingGranted = false
    var isCameraGranted = false
    var isMicrophoneGranted = false
    var isAccessibilityGranted = false
    var isAutoUpdateEnabled = false
    var isLaunchAtLoginEnabled = false
    
    // A reference to Sparkle updater to properly toggle auto-updates
    weak var updaterController: SPUStandardUpdaterController?

    // Real-time observation timer
    private var timer: Timer?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
        self.isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        self.isCameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        self.isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        self.isAccessibilityGranted = AXIsProcessTrusted()
        self.isAutoUpdateEnabled = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        self.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
    
    // Start real-time monitoring of statuses (useful when Permissions Window is open)
    func startMonitoring() {
        checkAllPermissions()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAllPermissions()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Triggers immediate re-evaluation of all permission states
    func checkAllPermissions() {
        // Read values that are safe on background/timer threads, update on Main
        let screenRecording = CGPreflightScreenCaptureAccess()
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        
        // AXIsProcessTrusted is fast & thread safe
        let accessibility = AXIsProcessTrusted()
        
        let autoUpdate = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        let launchLogin = SMAppService.mainApp.status == .enabled

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isScreenRecordingGranted = screenRecording
            self.isCameraGranted = camera
            self.isMicrophoneGranted = mic
            self.isAccessibilityGranted = accessibility
            self.isAutoUpdateEnabled = autoUpdate
            self.isLaunchAtLoginEnabled = launchLogin
        }
    }

    /// Are ALL mandatory system permissions granted?
    var hasAllRequiredPermissions: Bool {
        return isScreenRecordingGranted &&
               isCameraGranted &&
               isMicrophoneGranted &&
               isAccessibilityGranted
    }

    // MARK: - Recording permission gate

    /// A permission that must be granted before a recording can start, given the
    /// user's current toggles. Screen recording is ALWAYS required; microphone and
    /// camera only when their capture is enabled. Accessibility is deliberately not
    /// here — it only powers global hotkeys, never the recording itself.
    enum RecordingPermission: String, CaseIterable {
        case screenRecording
        case microphone
        case camera

        /// Human-readable name, matching the System Settings pane label.
        var title: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .microphone:       return "Microphone"
            case .camera:           return "Camera"
            }
        }

        /// The System Settings deep-link for granting this permission.
        var settingsPath: String {
            switch self {
            case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .microphone:       return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .camera:           return "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            }
        }
    }

    /// Which recording permissions are missing RIGHT NOW, given the toggles.
    ///
    /// Reads the system authorization APIs LIVE and synchronously rather than the
    /// cached `@Observable` flags — those are only refreshed while the Permissions
    /// window's 1-second timer is running, so at recording-start time they can be
    /// arbitrarily stale (e.g. the user revoked the mic in System Settings mid-session).
    static func missingForRecording(microphoneEnabled: Bool, cameraEnabled: Bool) -> [RecordingPermission] {
        var missing: [RecordingPermission] = []
        if !CGPreflightScreenCaptureAccess() {
            missing.append(.screenRecording)
        }
        if microphoneEnabled, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            missing.append(.microphone)
        }
        if cameraEnabled, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            missing.append(.camera)
        }
        return missing
    }

    /// For any still-undetermined required permission, shows the one-tap OS dialog and
    /// waits for the user's answer; then returns whatever is STILL missing. This makes
    /// the common first-run case (mic/camera never asked) a single system prompt instead
    /// of a trip to System Settings. Screen recording has no inline-grant path (the grant
    /// requires an app relaunch), so it is only ever reported, never prompted here.
    static func ensureRecordingPermissions(microphoneEnabled: Bool, cameraEnabled: Bool) async -> [RecordingPermission] {
        if microphoneEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if cameraEnabled, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        return missingForRecording(microphoneEnabled: microphoneEnabled, cameraEnabled: cameraEnabled)
    }

    /// Opens the System Settings pane for a missing recording permission. Used as the
    /// fallback when the SwiftUI Permissions window can't be summoned (e.g. launched to
    /// the menu bar at login with the main window never shown).
    static func openSystemSettings(for permission: RecordingPermission) {
        if let url = URL(string: permission.settingsPath) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Actions

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func requestCamera() {
        // When the status is still undetermined, just show the system prompt — don't
        // race it open System Settings off a stale `isCameraGranted`. Only jump to
        // Settings once the user has already denied/restricted access (the prompt
        // won't appear again, so Settings is the only path).
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .denied, .restricted:
            openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        default:
            break
        }
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        default:
            break
        }
    }

    func requestAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if !trusted {
            openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
    
    func toggleAutoUpdate() {
        let newState = !isAutoUpdateEnabled
        isAutoUpdateEnabled = newState // Optimistic UI update
        
        // Update Sparkle
        if let updater = updaterController?.updater {
            updater.automaticallyChecksForUpdates = newState
        } else {
            // Fallback if not injected
            UserDefaults.standard.set(newState, forKey: "SUEnableAutomaticChecks")
        }
        checkAllPermissions()
    }

    func toggleLaunchAtLogin() {
        let newState = !isLaunchAtLoginEnabled
        isLaunchAtLoginEnabled = newState // Optimistic UI update
        do {
            if newState {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
        checkAllPermissions()
    }

    private func openSettings(path: String) {
        if let url = URL(string: path) {
            NSWorkspace.shared.open(url)
        }
    }
}
