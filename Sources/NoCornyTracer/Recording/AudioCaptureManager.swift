import Foundation
import AVFoundation
import CoreMedia

/// Manages microphone audio capture with device selection
@Observable
final class AudioCaptureManager: NSObject {
    // MARK: - State
    var availableDevices: [AVCaptureDevice] = []
    var selectedDevice: AVCaptureDevice?
    var isCapturing = false
    var audioLevel: Float = 0

    // MARK: - Private
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.nocornytracer.audiocapture", qos: .userInitiated)

    // Callback for audio buffers
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Device Discovery

    func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        availableDevices = discoverySession.devices

        // Select default device if none selected
        if selectedDevice == nil {
            selectedDevice = AVCaptureDevice.default(for: .audio)
        }
    }

    func selectDevice(id: String) {
        selectedDevice = availableDevices.first { $0.uniqueID == id }
    }

    // MARK: - Capture

    func startCapture() throws {
        guard let device = selectedDevice else {
            throw AudioCaptureError.noDeviceSelected
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AudioCaptureError.cannotAddInput
        }
        session.addInput(input)

        // Add output
        let output = AVCaptureAudioDataOutput()
        let delegate = AudioOutputDelegate()
        delegate.onSampleBuffer = { [weak self] sampleBuffer in
            self?.onAudioSampleBuffer?(sampleBuffer)
            self?.updateAudioLevel(sampleBuffer)
        }
        output.setSampleBufferDelegate(delegate, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw AudioCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()

        self.captureSession = session
        self.audioOutput = output
        self._audioOutputDelegate = delegate
        self.isCapturing = true
    }

    // Hold a strong reference to the delegate
    private var _audioOutputDelegate: AudioOutputDelegate?

    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        _audioOutputDelegate = nil
        isCapturing = false
        audioLevel = 0
    }

    // MARK: - Audio Level

    private func updateAudioLevel(_ sampleBuffer: CMSampleBuffer) {
        guard let channelData = getChannelData(from: sampleBuffer) else { return }

        var sum: Float = 0
        let count = channelData.count
        for sample in channelData {
            sum += abs(sample)
        }

        let average = count > 0 ? sum / Float(count) : 0
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(average * 5, 1.0) // Normalize to 0...1
        }
    }

    private func getChannelData(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else { return nil }

        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        return Array(UnsafeBufferPointer(start: pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }, count: floatCount))
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDeviceSelected
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected: return "No audio input device selected"
        case .cannotAddInput: return "Cannot add audio input to capture session"
        case .cannotAddOutput: return "Cannot add audio output to capture session"
        }
    }
}

// MARK: - Audio Output Delegate

private final class AudioOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}
