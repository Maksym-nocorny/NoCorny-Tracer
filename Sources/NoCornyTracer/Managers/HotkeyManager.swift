import AppKit
import Carbon

/// Manages global keyboard shortcuts for recording control
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isStarted = false
    weak var appState: AppState?

    init() {}

    /// Start listening for global hotkeys
    func start(appState: AppState) {
        // Prevent multiple registrations
        guard !isStarted else { return }
        isStarted = true
        self.appState = appState

        // Check and request Accessibility permission
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )

        if !trusted {
            print("⌨️ Hotkeys: ⚠️ Accessibility permission required — macOS will show a prompt")
        }

        // Global monitor: captures key events when OTHER apps are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor: captures key events when THIS app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEventReturning(event) == true {
                return nil // Consume the event
            }
            return event
        }

        print("⌨️ Hotkeys: Global shortcuts registered")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isStarted = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        _ = handleKeyEventReturning(event)
    }

    /// Returns true if the event was handled
    private func handleKeyEventReturning(_ event: NSEvent) -> Bool {
        guard let appState = appState else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 15: // "R" key
            // ⌥⇧R → Start/Stop recording
            if flags == [.option, .shift] {
                print("⌨️ Hotkeys: ⌥⇧R pressed")
                Task { @MainActor in
                    if appState.recordingManager.isRecording {
                        await appState.stopRecording()
                    } else {
                        try? await appState.startRecording()
                    }
                }
                return true
            }

        case 35: // "P" key
            // ⌥⇧P → Pause/Resume
            if flags == [.option, .shift] {
                print("⌨️ Hotkeys: ⌥⇧P pressed")
                Task { @MainActor in
                    if appState.recordingManager.isRecording {
                        await appState.recordingManager.togglePause()
                    }
                }
                return true
            }

        case 7: // "X" key
            // ⌥⇧X → Abort (discard) recording
            if flags == [.option, .shift] {
                print("⌨️ Hotkeys: ⌥⇧X pressed — aborting")
                Task { @MainActor in
                    if appState.recordingManager.isRecording {
                        await appState.abortRecording()
                    }
                }
                return true
            }

        default:
            break
        }
        return false
    }

    deinit {
        stop()
    }
}
