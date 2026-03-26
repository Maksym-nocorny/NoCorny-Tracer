import SwiftUI
import AVFoundation

/// Main recording controls displayed in the menu bar popover
struct RecordingControlsView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Recording status / timer
            recordingStatusView

            // Main action button
            mainActionButton

            // Microphone controls
            microphoneSection
            
            // Camera controls
            cameraSection
        }
    }

    @Environment(\.dismiss) var dismiss
    
    // MARK: - Recording Status

    @ViewBuilder
    private var recordingStatusView: some View {
        if appState.recordingManager.isRecording {
            HStack(spacing: 8) {
                // ... (rest of recordingStatusView)
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .modifier(PulsingModifier(isActive: !appState.recordingManager.isPaused))

                Text(appState.recordingManager.formattedDuration)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                // Pause button
                Button {
                    appState.recordingManager.togglePause()
                } label: {
                    Image(systemName: appState.recordingManager.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Main Action Button

    @ViewBuilder
    private var mainActionButton: some View {
        if appState.recordingManager.isRecording {
            HStack(spacing: 8) {
                // Abort button
                Button {
                    Task { await appState.abortRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14))
                        Text("Abort")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.gray.gradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                // Stop button
                Button {
                    Task { await appState.stopRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.red.gradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        } else {
            Button {
                dismiss()
                Task {
                    try? await appState.startRecording()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 18))
                    Text("Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.blue.gradient)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    // MARK: - Microphone Section

    @ViewBuilder
    private var microphoneSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: appState.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(appState.isMicrophoneEnabled ? .green : .secondary)
                    .font(.system(size: 14))

                Text("Microphone")
                    .font(.system(size: 13))

                Spacer()

                Toggle("", isOn: $appState.isMicrophoneEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if appState.isMicrophoneEnabled {
                Picker("Input Device", selection: Binding(
                    get: { appState.selectedMicrophoneID ?? "" },
                    set: { appState.selectedMicrophoneID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default Input")
                        .tag("")
                    ForEach(appState.recordingManager.audioCaptureManager.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName)
                            .tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                // Audio level meter
                if appState.recordingManager.isRecording {
                    AudioLevelView(level: appState.recordingManager.audioCaptureManager.audioLevel)
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Camera Section

    @ViewBuilder
    private var cameraSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: appState.isCameraEnabled ? "camera.fill" : "camera.slash.fill")
                    .foregroundStyle(appState.isCameraEnabled ? .green : .secondary)
                    .font(.system(size: 14))

                Text("Camera")
                    .font(.system(size: 13))

                Spacer()

                Toggle("", isOn: $appState.isCameraEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if appState.isCameraEnabled {
                Picker("Capture Device", selection: $appState.selectedCameraDeviceID) {
                    ForEach(appState.cameraManager.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName)
                            .tag(device.uniqueID as String?)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Audio Level View

struct AudioLevelView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}

// MARK: - Pulsing Modifier

struct PulsingModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? (isPulsing ? 0.3 : 1.0) : 1.0)
            .animation(isActive ? .easeInOut(duration: 0.8).repeatForever() : .default, value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
