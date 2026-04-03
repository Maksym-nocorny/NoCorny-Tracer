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
            // Reconfigure session when device changes
            if isCapturing {
                Task { await restartSession() }
            }
        }
    }
    
    // The session to be displayed by a preview layer
    let captureSession = AVCaptureSession()
    
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
            deviceTypes: [.builtInWideAngleCamera, .external],
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
        
        // If already capturing and trying to start the SAME device, ignore.
        // We will allow starting if isCapturing is true ONLY if we are actively changing the device,
        // which avoids the race condition where stopSession() hasn't flipped isCapturing to false yet.
        let hasPermission = await requestPermission()
        guard hasPermission else {
            print("📷 CameraManager: Permission denied")
            return
        }
        
        guard let deviceID = selectedDeviceID,
              let device = availableDevices.first(where: { $0.uniqueID == deviceID }) else {
            print("📷 CameraManager: No valid device selected")
            return
        }
        
        // Prevent starting the same device if we're already capturing it
        if isCapturing {
            if let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput,
               currentInput.device.uniqueID == deviceID {
                return
            }
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
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        Task { @MainActor in
            self.isCapturing = false
        }
    }
    
    private func restartSession() async {
        // Just call startSession which now properly reconfigures inputs even if already running
        await startSession()
    }
}
