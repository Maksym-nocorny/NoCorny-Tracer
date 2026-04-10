import SwiftUI
import AVFoundation

/// Main recording controls
struct RecordingControlsView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Main action button
            mainActionButton

            // Microphone controls
            microphoneSection

            // Camera controls
            cameraSection
        }
    }

    // MARK: - Main Action Button

    @ViewBuilder
    private var mainActionButton: some View {
        if appState.recordingManager.isRecording {
            HStack(spacing: Theme.Spacing.md) {
                // Abort button
                Button {
                    Task { await appState.abortRecording() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14))
                        Text("Abort")
                            .font(Theme.Typography.body(13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.Colors.neutralGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                // Pause / Resume button
                Button {
                    Task { await appState.recordingManager.togglePause() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: appState.recordingManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14))
                        Text(appState.recordingManager.isPaused ? "Resume" : "Pause")
                            .font(Theme.Typography.body(13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.adaptive(light: Color(hex: 0x3E0693), dark: Color(hex: 0xA855F7)))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                // Stop button
                Button {
                    Task { await appState.stopRecording() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                        Text("Stop")
                            .font(Theme.Typography.body(13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.Colors.dangerGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        } else {
            Button {
                Task {
                    NSApp.windows.first { $0.title == "NoCorny Tracer" }?.orderOut(nil)
                    try? await appState.startRecording()
                }
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 18))
                    Text("Start Recording")
                        .font(Theme.Typography.body(14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.adaptive(light: Color(hex: 0x3E0693), dark: Color(hex: 0xA855F7)))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Microphone Section

    @ViewBuilder
    private var microphoneSection: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: appState.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(appState.isMicrophoneEnabled ? Theme.Colors.green : .secondary)
                .font(.system(size: 14))

            Text("Microphone")
                .font(Theme.Typography.body(13))

            // Audio level meter inline between label and toggle
            if appState.isMicrophoneEnabled && appState.recordingManager.isRecording {
                AudioLevelView(level: appState.recordingManager.audioCaptureManager.audioLevel)
                    .frame(height: 4)
            } else {
                Spacer()
            }

            Toggle("", isOn: $appState.isMicrophoneEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Camera Section

    @ViewBuilder
    private var cameraSection: some View {
        HStack {
            Image(systemName: appState.isCameraEnabled ? "camera.fill" : "camera.slash.fill")
                .foregroundStyle(appState.isCameraEnabled ? Theme.Colors.green : .secondary)
                .font(.system(size: 14))

            Text("Camera")
                .font(Theme.Typography.body(13))

            Spacer()

            Toggle("", isOn: $appState.isCameraEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
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
        if level > 0.8 { return Theme.Colors.red }
        if level > 0.5 { return Theme.Colors.yellow }
        return Theme.Colors.green
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
