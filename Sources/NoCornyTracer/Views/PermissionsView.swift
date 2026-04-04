import SwiftUI

/// A dedicated window view that lists all required permissions and states.
struct PermissionsView: View {
    @Bindable var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {

            // Header
            HStack(spacing: Theme.Spacing.xl) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .shadow(radius: 4)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Permissions")
                        .font(Theme.Typography.heading(24))
                    Text("Please grant the required permissions to ensure NoCorny Tracer works correctly.")
                        .font(Theme.Typography.body(13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, Theme.Spacing.md)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                // Screen Recording
                PermissionRowView(
                    icon: "display",
                    title: "Screen Recording",
                    description: "Required to capture your screen.",
                    isGranted: permissionsManager.isScreenRecordingGranted,
                    action: { permissionsManager.requestScreenRecording() }
                )

                // Camera
                PermissionRowView(
                    icon: "camera.fill",
                    title: "Camera",
                    description: "Required to show your face cam.",
                    isGranted: permissionsManager.isCameraGranted,
                    action: { permissionsManager.requestCamera() }
                )

                // Microphone
                PermissionRowView(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to record your voice.",
                    isGranted: permissionsManager.isMicrophoneGranted,
                    action: { permissionsManager.requestMicrophone() }
                )

                // Accessibility
                PermissionRowView(
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Required for global keyboard shortcuts.",
                    isGranted: permissionsManager.isAccessibilityGranted,
                    action: { permissionsManager.requestAccessibility() }
                )
            }
            .padding(.vertical, Theme.Spacing.md)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                // Auto-Update
                AppSettingRowView(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Auto-Update",
                    description: "Automatically check for app updates.",
                    isOn: Binding(
                        get: { permissionsManager.isAutoUpdateEnabled },
                        set: { _ in permissionsManager.toggleAutoUpdate() }
                    )
                )

                // Launch at Login
                AppSettingRowView(
                    icon: "play.rectangle.fill",
                    title: "Launch at Login",
                    description: "Start NoCorny Tracer automatically when you log in.",
                    isOn: Binding(
                        get: { permissionsManager.isLaunchAtLoginEnabled },
                        set: { _ in permissionsManager.toggleLaunchAtLogin() }
                    )
                )
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    // Just close the window
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)
        }
        .padding(Theme.Spacing.section)
        .frame(width: 520)
        .background(Theme.Colors.backgroundPrimary)
        .onAppear {
            permissionsManager.startMonitoring()
        }
        .onDisappear {
            permissionsManager.stopMonitoring()
        }
    }
}

private struct PermissionRowView: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .frame(width: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body(15, weight: .semibold))
                Text(description)
                    .font(Theme.Typography.body(13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.Colors.green)
            } else {
                Button("Grant") {
                    action()
                }
                .controlSize(.regular)
            }
        }
    }
}

private struct AppSettingRowView: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .frame(width: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body(15, weight: .semibold))
                Text(description)
                    .font(Theme.Typography.body(13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
