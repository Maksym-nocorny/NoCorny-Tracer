import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import AudioToolbox

/// Manages microphone audio capture.
///
/// By default the mic is captured RAW (no voice processing) for maximum fidelity — this matches
/// the clean quality of apps like Telegram. Apple Voice Processing (Voice Isolation + echo
/// cancellation) is the telephony DSP block FaceTime/Zoom use: it strongly attenuates background
/// TV/music/distant voices but audibly reshapes the voice (band-limiting + artifacts), so it's
/// opt-in via the `reduceBackgroundNoise` flag passed to `startCapture`. AGC is always left OFF
/// even when voice processing is on, because its automatic gain riding is the main "over-compressed"
/// artifact users notice. Uses AVAudioEngine so that, when enabled, the input runs through the same
/// processing path the system Mic Mode (Control Center → Voice Isolation) hooks into.
@Observable
final class AudioCaptureManager: NSObject {
    // MARK: - State
    var availableDevices: [AVCaptureDevice] = []
    var selectedDevice: AVCaptureDevice?
    var isCapturing = false
    var audioLevel: Float = 0

    /// Set true (once per capture) when the ambient noise floor stays high for a sustained
    /// window while recording RAW — i.e. the room is noisy enough that the user might want to
    /// turn on noise reduction. Observed by AppState to surface the suggestion toast.
    var environmentIsNoisy = false
    /// Fired once (on the main thread) the moment `environmentIsNoisy` flips true.
    var onEnvironmentNoisy: (() -> Void)?

    // MARK: - Private
    private var engine: AVAudioEngine?

    // MARK: - Ambient-noise detection
    // Only runs when capture started RAW (no voice processing) — there's no point suggesting
    // noise reduction if it's already on. We estimate the noise floor as a low percentile of the
    // recent per-buffer levels (the quiet gaps between speech): a HIGH floor means a noisy room.
    private var noiseDetectionEnabled = false
    private var noiseFiredThisSession = false
    private var noiseFloorWindow: [Float] = []   // recent per-buffer dBFS values
    private var noiseBuffersSeen = 0
    // Buffers arrive ~11.7/s (48 kHz / 4096). ~70 ≈ 6 s window; warm up ~8 s before judging.
    private let noiseWindowCapacity = 70
    private let noiseWarmupBuffers = 94
    // dBFS cutoff: if the 15th-percentile floor stays above this, call the room noisy.
    // Empirical — tune against quiet-room vs fan/TV logs.
    private let noiseFloorThresholdDB: Float = -50

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

    /// - Parameter reduceBackgroundNoise: when true, enables Apple Voice Processing (Voice
    ///   Isolation + echo cancellation, AGC off) to suppress background sound at the cost of some
    ///   fidelity. When false (the default), the mic is captured raw for maximum quality.
    func startCapture(reduceBackgroundNoise: Bool = false) throws {
        guard let device = selectedDevice else {
            throw AudioCaptureError.noDeviceSelected
        }

        // Backstop for the AppState permission gate: mic access should already be granted
        // by the time we get here. If it isn't (e.g. revoked in the split second between
        // the gate and now), fail loudly rather than install a tap that silently never
        // fires — the original "NO buffers received / silent audio track" failure.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            LogManager.shared.log("🎤 Audio: mic not authorized at capture start — aborting instead of recording a silent track.", type: .error)
            throw AudioCaptureError.permissionDenied
        }

        // Reset ambient-noise detection for this session. Only watch the floor when capturing raw.
        noiseDetectionEnabled = !reduceBackgroundNoise
        noiseFiredThisSession = false
        noiseFloorWindow.removeAll(keepingCapacity: true)
        noiseBuffersSeen = 0
        environmentIsNoisy = false

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

        // Voice processing is OPT-IN. When off (the default) we never touch it, so the input node
        // delivers the device's native, unprocessed format — the cleanest, highest-fidelity path.
        // When on, enable Voice Isolation + echo cancellation but keep AGC OFF (its auto-gain ride
        // is the main "over-compressed"/pumping artifact). Some virtual devices (Loopback/BlackHole)
        // don't support voice processing — fall back to raw capture gracefully.
        if reduceBackgroundNoise {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled = false
                input.isVoiceProcessingBypassed = false
                let isOn = input.isVoiceProcessingEnabled
                let agcOn = input.isVoiceProcessingAGCEnabled
                LogManager.shared.log("🎤 Audio: Voice processing ON (Voice Isolation + Echo Cancellation, AGC=\(agcOn)) — enabled=\(isOn)")
            } catch {
                LogManager.shared.log("⚠️ AudioCapture: voice processing not available on this device (\(error.localizedDescription)) — recording raw", type: .error)
            }
        } else {
            LogManager.shared.log("🎤 Audio: raw capture (voice processing off) — full fidelity")
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

        // Reset ambient-noise detection so a fresh capture starts clean.
        noiseDetectionEnabled = false
        noiseFiredThisSession = false
        noiseFloorWindow.removeAll(keepingCapacity: true)
        noiseBuffersSeen = 0
        environmentIsNoisy = false
    }

    // MARK: - Audio Level

    private func updateAudioLevel(from pcmBuffer: AVAudioPCMBuffer) {
        guard let channels = pcmBuffer.floatChannelData else { return }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }

        // Single pass: mean-abs drives the level meter, sum-of-squares gives RMS for noise detection.
        let channel0 = channels[0]
        var sumAbs: Float = 0
        var sumSquares: Float = 0
        for i in 0..<frames {
            let sample = channel0[i]
            sumAbs += abs(sample)
            sumSquares += sample * sample
        }
        let average = sumAbs / Float(frames)
        let rms = (sumSquares / Float(frames)).squareRoot()

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(average * 5, 1.0)
        }

        analyzeNoiseFloor(rms: rms)
    }

    /// Tracks the ambient noise floor and, once confident the room is noisy, flips
    /// `environmentIsNoisy` and fires `onEnvironmentNoisy` exactly once per capture.
    /// Runs on the audio tap thread; only the observable flip + callback hop to main.
    private func analyzeNoiseFloor(rms: Float) {
        guard noiseDetectionEnabled, !noiseFiredThisSession else { return }

        let db = 20 * log10(max(rms, 1e-7))
        noiseFloorWindow.append(db)
        if noiseFloorWindow.count > noiseWindowCapacity {
            noiseFloorWindow.removeFirst(noiseFloorWindow.count - noiseWindowCapacity)
        }
        noiseBuffersSeen += 1

        // Wait for the warm-up window and a full sample window before judging.
        guard noiseBuffersSeen >= noiseWarmupBuffers, noiseFloorWindow.count >= noiseWindowCapacity else { return }

        // Noise floor = 15th-percentile level (the quiet gaps, not speech peaks).
        let sorted = noiseFloorWindow.sorted()
        let floorIndex = max(0, min(sorted.count - 1, Int(0.15 * Float(sorted.count))))
        let floorDB = sorted[floorIndex]

        if floorDB > noiseFloorThresholdDB {
            noiseFiredThisSession = true
            LogManager.shared.log("🎤 Audio: noisy environment detected — floor=\(String(format: "%.1f", floorDB)) dBFS (> \(Int(noiseFloorThresholdDB)) dBFS). Suggesting noise reduction.")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.environmentIsNoisy = true
                self.onEnvironmentNoisy?()
            }
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
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected: return "No audio input device selected"
        case .engineStartFailed: return "Failed to start audio engine"
        case .permissionDenied:  return "Microphone access is not granted"
        }
    }
}
