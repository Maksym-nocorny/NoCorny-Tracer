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
        checkAllPermissions()
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

    /// Are ALL tracked permissions and settings granted/enabled?
    var hasAllRequiredPermissions: Bool {
        return isScreenRecordingGranted &&
               isCameraGranted &&
               isMicrophoneGranted &&
               isAccessibilityGranted &&
               isAutoUpdateEnabled &&
               isLaunchAtLoginEnabled
    }
    
    // MARK: - Actions

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        if !isCameraGranted {
            openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !isMicrophoneGranted {
            openSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
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
