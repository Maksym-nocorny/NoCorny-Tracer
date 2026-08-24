import AppKit
import Carbon.HIToolbox

/// Manages global keyboard shortcuts for recording control.
///
/// Carbon `RegisterEventHotKey` instead of the old `NSEvent` global monitor: the monitor
/// required the Accessibility permission (with a scary system prompt on first launch) and
/// silently delivered nothing without it. Carbon hot keys work system-wide with no
/// permission at all, are delivered once per press (no auto-repeat storm), and reach us
/// with no app focused on ours — so the old local monitor is gone too.
final class HotkeyManager {

    /// What a hot key does. The id→action mapping is pure so the wiring is testable
    /// without registering anything with the system.
    enum HotkeyAction: CaseIterable, Equatable {
        case toggleRecording   // ⌥⇧R — start/stop
        case togglePause       // ⌥⇧P — pause/resume
        case abortRecording    // ⌥⇧X — discard
    }

    struct HotkeyBinding: Equatable {
        let id: UInt32
        let keyCode: UInt32
        let action: HotkeyAction
    }

    /// ⌥⇧ + R / P / X — the exact combos (and key codes 15/35/7) of the NSEvent
    /// implementation this replaced.
    static let bindings: [HotkeyBinding] = [
        HotkeyBinding(id: 1, keyCode: UInt32(kVK_ANSI_R), action: .toggleRecording),
        HotkeyBinding(id: 2, keyCode: UInt32(kVK_ANSI_P), action: .togglePause),
        HotkeyBinding(id: 3, keyCode: UInt32(kVK_ANSI_X), action: .abortRecording),
    ]

    static func action(forHotKeyID id: UInt32) -> HotkeyAction? {
        bindings.first { $0.id == id }?.action
    }

    /// 'NCTR' — marks our registrations in the Carbon callback.
    private static let signature: OSType = 0x4E435452

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private(set) var isStarted = false
    weak var appState: AppState?

    init() {}

    /// Start listening for global hotkeys.
    func start(appState: AppState) {
        // Prevent multiple registrations (a second RegisterEventHotKey for the same
        // combo fails, but the guard keeps the refs/handler bookkeeping simple).
        guard !isStarted else { return }
        isStarted = true
        self.appState = appState

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C function pointer — no captures; the manager travels through userData.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return status }
            Unmanaged<HotkeyManager>.fromOpaque(userData)
                .takeUnretainedValue()
                .handleHotKey(id: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let modifiers = UInt32(optionKey | shiftKey)
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(
                binding.keyCode,
                modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                print("⌨️ Hotkeys: ⚠️ failed to register hot key id \(binding.id) — OSStatus \(status)")
            }
        }

        print("⌨️ Hotkeys: Carbon hot keys registered (\(hotKeyRefs.count)/\(Self.bindings.count))")
    }

    func stop() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        isStarted = false
    }

    /// Same actions, 1:1, as the NSEvent implementation this replaced.
    private func handleHotKey(id: UInt32) {
        guard let action = Self.action(forHotKeyID: id), let appState else { return }

        switch action {
        case .toggleRecording:
            print("⌨️ Hotkeys: ⌥⇧R pressed")
            Task { @MainActor in
                if appState.recordingManager.isRecording {
                    await appState.stopRecording()
                } else {
                    try? await appState.startRecording()
                }
            }
        case .togglePause:
            print("⌨️ Hotkeys: ⌥⇧P pressed")
            Task { @MainActor in
                if appState.recordingManager.isRecording {
                    await appState.recordingManager.togglePause()
                }
            }
        case .abortRecording:
            print("⌨️ Hotkeys: ⌥⇧X pressed — aborting")
            Task { @MainActor in
                if appState.recordingManager.isRecording {
                    await appState.abortRecording()
                }
            }
        }
    }

    deinit {
        stop()
    }
}
