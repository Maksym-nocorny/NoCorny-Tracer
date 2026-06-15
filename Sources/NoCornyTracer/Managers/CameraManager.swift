import Foundation
import AVFoundation

/// Manages camera discovery, permissions, and AVCaptureSession
@Observable
final class CameraManager {
    // MARK: - State
    var isEnabled: Bool = false
    var isCapturing: Bool = false
    var availableDevices: [AVCaptureDevice] = []
    var selectedDeviceID: String? {
        didSet {
            // Reconfigure session when device changes. All session mutation is
            // serialized onto sessionQueue so a device switch queued mid-start
            // runs after the in-flight start completes (FIFO).
            guard isEnabled, isCapturing else { return }
            let deviceID = selectedDeviceID
            sessionQueue.async { [weak self] in
                self?.configureAndStart(deviceID: deviceID)
            }
        }
    }

    // The session to be displayed by a preview layer
    let captureSession = AVCaptureSession()

    /// Serializes ALL AVCaptureSession reconfiguration (start/stop/device-switch)
    /// onto one background queue. AVCaptureSession is not thread-safe; funnelling
    /// every begin/commitConfiguration + start/stopRunning through this queue
    /// avoids data races and keeps the blocking calls off the main thread.
    private let sessionQueue = DispatchQueue(label: "agency.nocorny.tracer.camera.session")
    
    // MARK: - Initialization
    init() {
        refreshDevices()
    }
    
    // MARK: - Permissions & Discovery
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
    
    func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        
        // Filter out suspended devices and sort
        let devices = discoverySession.devices
        
        Task { @MainActor in
            self.availableDevices = devices
            
            // Auto-select first device if none selected
            if self.selectedDeviceID == nil || !devices.contains(where: { $0.uniqueID == self.selectedDeviceID }) {
                self.selectedDeviceID = devices.first?.uniqueID
            }
        }
    }
    
    // MARK: - Session Management
    
    func startSession() async {
        guard isEnabled else { return }

        // requestPermission() suspends — it must run OFF the session queue.
        let hasPermission = await requestPermission()
        guard hasPermission else {
            print("📷 CameraManager: Permission denied")
            return
        }

        // Snapshot the desired device, then hand the blocking reconfiguration
        // to the serial queue. Everything that touches captureSession lives in
        // configureAndStart so the session is mutated from exactly one thread.
        let deviceID = selectedDeviceID
        sessionQueue.async { [weak self] in
            self?.configureAndStart(deviceID: deviceID)
        }
    }

    /// Performs the actual AVCaptureSession reconfiguration + start.
    /// MUST be called on `sessionQueue`.
    private func configureAndStart(deviceID: String?) {
        guard let deviceID,
              let device = availableDevices.first(where: { $0.uniqueID == deviceID }) else {
            print("📷 CameraManager: No valid device selected")
            return
        }

        // Prevent re-adding the same device if it's already the running input.
        // Read consistently here on the session queue.
        if captureSession.isRunning,
           let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput,
           currentInput.device.uniqueID == deviceID {
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)

            captureSession.beginConfiguration()

            // Clear existing inputs
            for oldInput in captureSession.inputs {
                captureSession.removeInput(oldInput)
            }

            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                print("📷 CameraManager: Could not add input to session")
            }

            captureSession.commitConfiguration()

            if !captureSession.isRunning {
                captureSession.startRunning()
            }

            Task { @MainActor in
                self.isCapturing = true
            }
        } catch {
            print("📷 CameraManager: Failed to create device input - \(error)")
        }
    }

    func stopSession() {
        // Dispatch the blocking stopRunning() off the main thread and onto the
        // serial queue so it can't freeze the UI and is ordered behind any
        // queued start/reconfigure. Signature stays synchronous for callers.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            Task { @MainActor in
                self.isCapturing = false
            }
        }
    }
}
