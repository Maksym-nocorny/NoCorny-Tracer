import AppKit
import ScreenCaptureKit

// MARK: - Pure decision (covered by ThemeDecisionTests)

/// The Auto theme's hysteresis (4.1.0, наказ шефа: «якщо текст стає
/// нечитабельним — перемикається тема»): a bright backdrop wants the LIGHT look
/// (ink text on light frost), a dark backdrop wants the DARK look (white text on
/// navy glass), and the band between the thresholds holds whatever is currently
/// shown — so a backdrop hovering around one threshold can never make the bar
/// strobe between themes.
enum ThemeDecision {
    enum Look: Equatable {
        case light
        case dark
    }

    /// Mean backdrop luminance ABOVE this → the light look.
    static let lightThreshold: Double = 0.62
    /// Mean backdrop luminance BELOW this → the dark look.
    static let darkThreshold: Double = 0.45

    /// Strictly-above / strictly-below: a luminance sitting exactly ON a
    /// threshold is still inside the holding band.
    static func next(current: Look, luminance: Double) -> Look {
        if luminance > lightThreshold { return .light }
        if luminance < darkThreshold { return .dark }
        return current
    }
}

// MARK: - Monitor

/// Samples the desktop UNDER the command-bar panel and drives the Auto theme
/// (4.1.0). The screenshot comes through ScreenCaptureKit — the Screen Recording
/// permission the app already needs to exist is the legitimate superpower here —
/// with every window of OUR OWN process excluded from the capture, so the panel
/// never measures its own glass or a toast hovering nearby. (No panel registry
/// needed for that: SCWindow carries `owningApplication.processID`, and filtering
/// by our PID excludes every present and future panel in one stroke.)
///
/// Cadence: one sample per second while the panel is visible, plus a debounced
/// (~0.7s) immediate sample after moves/reframes/Space switches. The panel gone →
/// the monitor sleeps. Without the screen permission (before onboarding) it stays
/// silent — no sampling, no prompting: the Auto theme then follows the system.
@MainActor
final class BackdropLuminanceMonitor {

    /// Fired on the main actor whenever the decided look CHANGES.
    var onLook: ((ThemeDecision.Look) -> Void)?

    private(set) var currentLook: ThemeDecision.Look?

    private weak var panel: NSPanel?
    private var timer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?
    private var isSampling = false

    // MARK: Lifecycle

    /// Idempotent: a second `start` for the same running monitor just retargets
    /// the panel. The first sample fires immediately.
    func start(panel: NSPanel) {
        self.panel = panel
        guard timer == nil else { return }
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sampleNow() }
        }
        timer = heartbeat
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleSoon() }
        }
        Task { @MainActor [weak self] in await self?.sampleNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounceTask?.cancel()
        debounceTask = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
    }

    /// Debounced sample (~0.7s) for event storms: window drags and reframes fire
    /// continuously, and a capture per event would be waste.
    func sampleSoon() {
        guard timer != nil else { return }   // not started → stay asleep
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.sampleNow()
        }
    }

    // MARK: Sampling

    private func sampleNow() async {
        guard !isSampling else { return }
        guard let panel, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        // Before the Screen Recording grant the monitor is mute — never a prompt.
        guard CGPreflightScreenCaptureAccess() else { return }
        isSampling = true
        defer { isSampling = false }

        // The glass rect plus a 20pt apron — what the surface actually sits over.
        let rect = MorphGeometry.logicalFrame(forPanel: panel.frame).insetBy(dx: -20, dy: -20)
        guard let luminance = try? await Self.sampleLuminance(under: rect, on: screen) else { return }

        let look = ThemeDecision.next(current: currentLook ?? .dark, luminance: luminance)
        guard look != currentLook else { return }
        currentLook = look
        onLook?(look)
    }

    private struct SampleFailed: Error {}

    /// One screenshot of the backdrop under `rect` (global AppKit coordinates) on
    /// `screen`, downscaled to ~32px on the long side, averaged to a luminance.
    nonisolated static func sampleLuminance(under rect: CGRect, on screen: NSScreen) async throws -> Double {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = AreaSelectionWindowManager.displayID(of: screen),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SampleFailed()
        }

        // Exclude every window of our own process — the bar itself, toasts,
        // pills, the camera bubble: the backdrop is what's UNDER us, not us.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ourWindows = content.windows.filter { $0.owningApplication?.processID == myPID }
        let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

        // Display-local top-left points — the space sourceRect is documented in
        // (same conversion CaptureGeometry uses), clamped to the display.
        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        ).intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard !local.isEmpty else { throw SampleFailed() }

        let config = SCStreamConfiguration()
        config.sourceRect = local
        let scale = 32.0 / max(local.width, local.height, 1)
        config.width = max(4, Int(local.width * scale))
        config.height = max(4, Int(local.height * scale))
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return averageLuminance(of: image)
    }

    /// Mean Rec.709 luminance in gamma space (0…1). Gamma-space averaging is a
    /// deliberate approximation: the thresholds were tuned against it, and for a
    /// bright-vs-dark verdict the linearization would only move both thresholds.
    nonisolated static func averageLuminance(of image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(width * height)
    }
}
