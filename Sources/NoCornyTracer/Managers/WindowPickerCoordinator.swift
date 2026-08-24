import AppKit
import ScreenCaptureKit

/// Thin wrapper over the system window picker (SCContentSharingPicker, macOS 14+).
///
/// Flow (decision, phase 6a): the command bar's "Window" row ALWAYS opens this picker —
/// picking a window saves it into CaptureSelection AND starts recording immediately; the
/// record button is what reuses the remembered window without a picker. One row, one
/// meaning, no modal "just set the mode" state. Cancel changes nothing.
///
/// Why the picked SCWindow has to be re-resolved at all: the picker's observer hands back
/// an opaque SCContentFilter, and macOS 14 has NO public API to read the picked window out
/// of it (no includedWindows; SCShareableContentInfo only re-states style/rect/scale). The
/// filter does expose the picked content's frame (`contentRect`, points, global space), so
/// the SCWindow is found by matching that frame against a fresh SCShareableContent
/// snapshot. Two windows with identical frames are ambiguous; the on-screen, layer-0 match
/// wins, which in practice is the window the person could see and click in the picker.
///
/// Fallback: if the system picker cannot start (`contentSharingPickerStartDidFail` — real
/// on some macOS 14 builds) or the frame match finds nothing, a plain NSMenu listing the
/// on-screen windows stands in. Same contract: choosing an item hands the SCWindow to the
/// caller; dismissing it changes nothing.
final class WindowPickerCoordinator: NSObject {
    @MainActor static let shared = WindowPickerCoordinator()

    /// Completion for the presentation in flight. Touched only on the main actor.
    private var onPick: ((SCWindow) -> Void)?
    /// The shared picker keeps observers forever; add ours once, not per presentation.
    private var observerAdded = false

    // MARK: - Entry point

    @MainActor
    func pickWindow(onPick: @escaping (SCWindow) -> Void) {
        self.onPick = onPick

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        // One-shot pick: we never keep a stream attached to the picker, so there is no
        // "change what you're sharing" flow for the system UI to offer.
        configuration.allowsChangingSelectedContent = false

        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        if !observerAdded {
            picker.add(self)
            observerAdded = true
        }
        picker.isActive = true
        picker.present(using: .window)
    }

    /// Takes the pending completion (one shot) and puts the shared picker back to sleep.
    @MainActor
    private func settle() -> ((SCWindow) -> Void)? {
        let handler = onPick
        onPick = nil
        SCContentSharingPicker.shared.isActive = false
        return handler
    }

    // MARK: - Filter → SCWindow

    /// Frame-matches the picker's opaque filter back to a concrete SCWindow (see the type
    /// comment for why this indirection exists at all). 1pt tolerance absorbs float noise;
    /// the frames come from the same WindowServer, so a real match is byte-identical.
    static func resolvePickedWindow(matching filter: SCContentFilter) async -> SCWindow? {
        guard filter.style == .window else { return nil }
        let target = filter.contentRect
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let matches = content.windows.filter { window in
            abs(window.frame.minX - target.minX) < 1 &&
            abs(window.frame.minY - target.minY) < 1 &&
            abs(window.frame.width - target.width) < 1 &&
            abs(window.frame.height - target.height) < 1
        }
        return matches.first(where: { $0.isOnScreen && $0.windowLayer == 0 }) ?? matches.first
    }

    // MARK: - Fallback window list

    /// Kept across the NSMenu's tracking loop so the picked item can reach the caller.
    private var fallbackHandler: ((SCWindow) -> Void)?

    @MainActor
    private func presentFallbackMenu(onPick: @escaping (SCWindow) -> Void) {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let candidates = content.windows.filter { window in
                window.isOnScreen &&
                window.windowLayer == 0 &&                                // real windows, not menu bar / dock furniture
                window.frame.width >= CaptureGeometry.minimumSide &&
                window.frame.height >= CaptureGeometry.minimumSide &&
                window.owningApplication?.processID != myPID &&           // recording our own panels helps nobody
                !(window.title ?? "").isEmpty
            }
            guard !candidates.isEmpty else {
                LogManager.shared.log("Window picker: fallback list found no windows to offer", type: .error)
                return
            }
            self.fallbackHandler = onPick
            let menu = NSMenu(title: "Record a Window")
            for window in candidates {
                let appName = window.owningApplication?.applicationName ?? ""
                let windowTitle = window.title ?? ""
                let label = appName.isEmpty ? windowTitle : "\(appName) - \(windowTitle)"
                let item = NSMenuItem(title: String(label.prefix(60)), action: #selector(self.fallbackItemPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = window
                menu.addItem(item)
            }
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @MainActor
    @objc private func fallbackItemPicked(_ item: NSMenuItem) {
        guard let window = item.representedObject as? SCWindow else { return }
        let handler = fallbackHandler
        fallbackHandler = nil
        handler?(window)
    }
}

// MARK: - SCContentSharingPickerObserver

extension WindowPickerCoordinator: SCContentSharingPickerObserver {
    // The picker calls these on its own queue; all state lives behind the main actor.

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            _ = self.settle()  // Cancel → nothing (decision, phase 6a): mode and memory stay as they were.
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard let handler = self.settle() else { return }
            if let window = await Self.resolvePickedWindow(matching: filter) {
                handler(window)
            } else {
                LogManager.shared.log("Window picker: could not match the picked content back to a window - offering the window list instead", type: .error)
                self.presentFallbackMenu(onPick: handler)
            }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            guard let handler = self.settle() else { return }
            LogManager.shared.log("Window picker: system picker failed to start (\(error.localizedDescription)) - offering the window list instead", type: .error)
            self.presentFallbackMenu(onPick: handler)
        }
    }
}
