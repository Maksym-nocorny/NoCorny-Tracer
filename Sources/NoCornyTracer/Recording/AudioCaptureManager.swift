import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import AudioToolbox

/// Manages microphone audio capture with Apple Voice Processing (noise suppression + echo cancellation).
/// Uses AVAudioEngine instead of AVCaptureSession so the input runs through the same DSP block
/// FaceTime/Zoom use, which strongly attenuates background TV, music, and distant voices.
@Observable
final class AudioCaptureManager: NSObject {
    // MARK: - State
    var availableDevices: [AVCaptureDevice] = []
    var selectedDevice: AVCaptureDevice?
    var isCapturing = false
    var audioLevel: Float = 0

    // MARK: - Private
    private var engine: AVAudioEngine?

    // Diagnostics for the first 2 seconds of capture — helps catch silent failures
    // (voice processing not engaging, hostTime always zero, no buffers arriving).
    private var diagBuffersReceived: Int = 0
    private var diagBuffersWithValidPTS: Int = 0
    private var diagFallbackPTSCount: Int = 0
    private var diagHealthCheckScheduled = false

    // Callback for audio buffers (kept identical to the previous AVCaptureSession-based API
    // so RecordingManager and VideoWriter need no changes).
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

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route the engine's input to the user-selected device. Without this the engine
        // uses the system default input, which would silently override Settings.
        if let deviceID = audioDeviceID(forUID: device.uniqueID) {
            let ok = setInputDevice(deviceID, on: input)
            if !ok {
                print("⚠️ AudioCapture: failed to bind device \(device.localizedName), falling back to default")
            }
        } else {
            print("⚠️ AudioCapture: could not resolve AudioDeviceID for UID \(device.uniqueID), using default")
        }

        // Enable Apple Voice Processing (voice isolation + AGC + echo cancellation).
        // Available since macOS 13; deployment target is 14, so always callable.
        // Some virtual devices (Loopback/BlackHole) don't support it — fall back gracefully.
        do {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            input.isVoiceProcessingBypassed = false
            let isOn = input.isVoiceProcessingEnabled
            let agcOn = input.isVoiceProcessingAGCEnabled
            let bypassed = input.isVoiceProcessingBypassed
            LogManager.shared.log("🎤 Audio: Voice processing → enabled=\(isOn), AGC=\(agcOn), bypassed=\(bypassed) (Voice Isolation + AGC + Echo Cancellation active)")
        } catch {
            LogManager.shared.log("⚠️ AudioCapture: voice processing not available on this device (\(error.localizedDescription)) — recording without it", type: .error)
        }

        // Read format AFTER toggling voice processing, since enabling it can reshape the
        // node's output format.
        let inputFormat = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, when in
            guard let self = self else { return }
            self.diagBuffersReceived += 1
            if when.hostTime != 0 {
                self.diagBuffersWithValidPTS += 1
            }
            self.updateAudioLevel(from: pcmBuffer)
            if let sampleBuffer = self.makeSampleBuffer(from: pcmBuffer, time: when) {
                self.onAudioSampleBuffer?(sampleBuffer)
            }
        }

        // Reset diagnostics for this capture session
        diagBuffersReceived = 0
        diagBuffersWithValidPTS = 0
        diagFallbackPTSCount = 0
        diagHealthCheckScheduled = true

        // prepare() preallocates buffers and primes the audio graph before start() opens
        // the floodgates — gives voice processing a small head start on initialization.
        engine.prepare()

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            diagHealthCheckScheduled = false
            throw error
        }

        self.engine = engine
        self.isCapturing = true

        // Health check at 2s: if no buffers received or all PTS were invalid, log loudly
        // so the next bug report has data to act on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runAudioHealthCheck()
        }
    }

    private func runAudioHealthCheck() {
        guard diagHealthCheckScheduled else { return }
        diagHealthCheckScheduled = false
        guard isCapturing else { return }

        let total = diagBuffersReceived
        let valid = diagBuffersWithValidPTS
        let fallback = diagFallbackPTSCount

        if total == 0 {
            LogManager.shared.log("⚠️ Audio: NO buffers received in first 2s — voice processing may have failed to engage. Recording will likely have silent audio track.", type: .error)
        } else if valid == 0 {
            LogManager.shared.log("⚠️ Audio: \(total) buffers received but ALL had invalid hostTime (=0). PTS computed via host-clock fallback (\(fallback) times). A/V sync may drift.", type: .error)
        } else if fallback > 0 {
            LogManager.shared.log("🎤 Audio health: \(total) buffers in 2s, \(valid) with valid PTS, \(fallback) used fallback timing.")
        } else {
            LogManager.shared.log("🎤 Audio health OK: \(total) buffers in 2s, all with valid PTS.")
        }
    }

    func stopCapture() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            // Try to disable voice processing so the next capture starts from a clean state.
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine.stop()
        }
        engine = nil
        isCapturing = false
        audioLevel = 0
        diagHealthCheckScheduled = false
    }

    // MARK: - Audio Level

    private func updateAudioLevel(from pcmBuffer: AVAudioPCMBuffer) {
        guard let channels = pcmBuffer.floatChannelData else { return }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }

        let channel0 = channels[0]
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channel0[i])
        }
        let average = sum / Float(frames)

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(average * 5, 1.0)
        }
    }

    // MARK: - PCM Buffer → CMSampleBuffer

    /// Wraps an `AVAudioPCMBuffer` as a `CMSampleBuffer` that the existing `VideoWriter`
    /// AAC encoder accepts. The encoder performs any needed resampling/downmix on its own.
    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        let asbd = pcmBuffer.format.streamDescription

        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let formatDesc else { return nil }

        let frameCount = CMItemCount(pcmBuffer.frameLength)
        let sampleRate = asbd.pointee.mSampleRate

        // Compute PTS in the same clock domain as ScreenCaptureKit video buffers (host clock),
        // so AVAssetWriter accepts the audio after the session start time.
        // If the tap delivered AVAudioTime with hostTime == 0 (which happens on some
        // devices / first warm-up cycles), fall back to the host clock directly.
        let pts: CMTime
        if time.hostTime != 0 {
            let hostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            pts = CMTime(seconds: hostSeconds, preferredTimescale: CMTimeScale(sampleRate))
        } else {
            pts = CMClockGetTime(CMClockGetHostTimeClock())
            diagFallbackPTSCount += 1
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        // Copies the PCM samples into a fresh CMBlockBuffer attached to the CMSampleBuffer,
        // so the AVAudioPCMBuffer can be released safely after this call returns.
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.audioBufferList
        )
        guard status == noErr else { return nil }

        return sampleBuffer
    }

    // MARK: - HAL Device Selection

    /// Looks up the Core Audio `AudioDeviceID` whose `kAudioDevicePropertyDeviceUID`
    /// matches the given AVCaptureDevice `uniqueID` (which is also the HAL UID on macOS).
    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        guard status == noErr else { return nil }

        for device in devices {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var deviceUID: CFString?
            status = withUnsafeMutablePointer(to: &deviceUID) { ptr in
                AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, ptr)
            }
            guard status == noErr, let cfString = deviceUID else { continue }
            if (cfString as String) == uid {
                return device
            }
        }
        return nil
    }

    /// Sets the input device on the engine's input audio unit. Note: even though it's an
    /// input unit, the property name is `kAudioOutputUnitProperty_CurrentDevice` (Apple naming).
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) -> Bool {
        guard let audioUnit = inputNode.audioUnit else { return false }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDeviceSelected
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected: return "No audio input device selected"
        case .engineStartFailed: return "Failed to start audio engine"
        }
    }
}
