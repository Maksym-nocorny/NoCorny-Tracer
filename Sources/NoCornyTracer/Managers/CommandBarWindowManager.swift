import SwiftUI
import AppKit

// MARK: - Panel

/// The borderless panel that hosts the command bar — and, on the same window,
/// the recording pill.
///
/// ROUND 12 (вердикт шефа 26.08: «я перемикаюсь на інше вікно, а трейсер не
/// зникає, бо він завжди поверх»). Until now this panel had ONE personality —
/// floating, on every Space, never captured — and wore it on every surface. That
/// is right for the pill and wrong for everything else: the bar and its drawers
/// are the app's ordinary window and must behave like one. So the panel now
/// changes personality with the surface (`CommandBarWindowManager.windowTraits`):
///
/// - BAR / DRAWERS: `level = .normal`, no `.nonactivatingPanel`, no
///   `canJoinAllSpaces`, `sharingType = .readOnly`. Switch apps and it goes
///   BEHIND them like any window; click it and the app activates like any window;
///   screenshots and recordings see it, which is now correct and expected.
/// - RECORDING PILL: `level = .floating`, `.nonactivatingPanel`,
///   `canJoinAllSpaces + fullScreenAuxiliary`, `sharingType = .none`. It is the
///   only control surface of a live take, so it stays on top, follows the user
///   across Spaces, never steals focus from what is being recorded, and NEVER
///   joins the capture — the one sacred invariant of this file.
///
/// `hidesOnDeactivate` is false on both: going behind another app is the point,
/// vanishing is not. `hasShadow` is off because the SwiftUI content draws the
/// redesign's own shadow (`.floatingPanelShadow()`), and `canBecomeKey` is
/// overridden because a borderless window refuses the keyboard otherwise.
///
/// ЗАМІР (стенд r12, macOS 26.5.2) — ЧОМУ ОДНЕ ВІКНО, А НЕ ДВА. Мутація
/// `styleMask` на живому вікні виявилась безкоштовною: 12 перемикань
/// `.nonactivatingPanel` туди-сюди по 0.15с дали 35 ПОБАЙТОВО ОДНАКОВИХ кадрів
/// бурсту — ані мигання, ані тайтлбару, ані втрати вмісту; сам виклик ~0.1мс, і
/// borderless, прозорість, тінь, рамка, `contentView`, `canBecomeKey` переживають
/// його без єдиної зміни. Рівень, `collectionBehavior` і `sharingType` теж
/// перемикаються на місці. Два окремі вікна натомість знесли б композиторний
/// політ round 5c: він тримається на тому, що ОДНЕ вікно бере union обох
/// кінцевих рамок і возить вміст усередині нього — між двома вікнами такого
/// не зробиш, лишився б кросфейд.
final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc fallback for the drawers: fires when the panel is key and nothing in the
    /// SwiftUI hierarchy consumed the key (`.onExitCommand` needs focus INSIDE the
    /// drawer, which a bar the user merely clicked once does not hand out). Set by
    /// the manager.
    var onEsc: (() -> Void)?
    /// ⌘, toggles the Settings drawer (the hint the drawer header shows). Only
    /// works while the panel is key — same reach as Esc above.
    var onCmdComma: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onEsc { onEsc() } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEsc {   // 53 = Esc
            onEsc()
            return
        }
        super.keyDown(with: event)
    }

    // ⌘-shortcuts never reach keyDown — AppKit routes them through the key
    // window's performKeyEquivalent BEFORE the main menu. Intercepting here is
    // also what stops ⌘, from opening the empty placeholder Settings scene
    // (the documented phase-7 compromise) while the bar is key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == ",",
           let onCmdComma {
            onCmdComma()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Drag clamp (round 6)

    /// Round 6 («тягну вікно вниз — меню заходить за екран»; «сам застосунок не
    /// повинен покидати рамки екрану взагалі»): the CameraOverlayWindow clamp
    /// recipe, adapted to the shadow apron — what must stay inside the visible
    /// frame is the LOGICAL glass rect, not the panel (which is `panelShadowInset`
    /// larger on every side; its transparent apron is SUPPOSED to hang past the
    /// edge when the glass sits flush against it). `constrainFrameRect` covers
    /// AppKit-driven placement including user drags, `setFrameOrigin` the
    /// origin-only path. Programmatic `setFrame` calls from the manager are left
    /// alone on purpose: they all come pre-clamped out of
    /// `MorphGeometry.targetFrame`, and clamping a mid-flight union frame would
    /// corrupt the flight's offset base. The manager's `panelWasDragged` re-clamp
    /// is the safety net for any path that slips both overrides (the camera
    /// window's delegate plays the same role).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.clampedToVisible(frameRect, screen: screen ?? self.screen ?? NSScreen.main)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(
            Self.clampedToVisible(proposed, screen: self.screen ?? NSScreen.main).origin
        )
    }

    private static func clampedToVisible(_ frameRect: NSRect, screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frameRect }
        return MorphGeometry.clampedPanelFrame(frameRect, visible: visible)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: Self.styleMask(nonactivating: false),
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        // NSPanel hides itself when the app deactivates by default. That must NOT
        // happen on either personality: an ordinary window stays on screen when you
        // switch apps (it just stops being in front), and the pill stays put because
        // it is the only way to stop the take.
        hidesOnDeactivate = false
        // The manager re-dresses the panel for the real surface before it is ordered
        // in; the bar's traits are the honest starting point.
        apply(CommandBarWindowManager.windowTraits(for: .bar, takeLive: false))
    }

    /// The style mask of each personality. `.borderless` is the ABSENCE of
    /// `.titled` (its raw value is 0), so both variants stay chromeless — the
    /// r12 stand confirms `titled == false` through every flip.
    static func styleMask(nonactivating: Bool) -> NSWindow.StyleMask {
        let base: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        return nonactivating ? base.union(.nonactivatingPanel) : base
    }

    /// Re-dresses the live panel for a surface. Returns whether the window LEVEL
    /// changed, because that is the one trait whose flip needs a follow-up: a
    /// panel demoted out of the floating band lands wherever the z-order says,
    /// which for a returning bar means "behind whatever is in front".
    @discardableResult
    func apply(_ traits: CommandBarWindowManager.WindowTraits) -> Bool {
        let levelChanged = level != traits.level
        let mask = Self.styleMask(nonactivating: traits.nonactivating)
        if styleMask != mask { styleMask = mask }
        // `isFloatingPanel` is a level setter in disguise (and it resets
        // `hidesOnDeactivate` along the way), so it goes FIRST and the explicit
        // values below have the last word.
        isFloatingPanel = traits.level == .floating
        level = traits.level
        hidesOnDeactivate = false
        collectionBehavior = traits.collectionBehavior
        sharingType = traits.sharingType
        becomesKeyOnlyIfNeeded = traits.becomesKeyOnlyIfNeeded
        return levelChanged
    }
}

// MARK: - Hosting controller (first-mouse click-through)

/// Hosts the bar's SwiftUI tree and answers YES to `acceptsFirstMouse`.
///
/// Round 12 side effect worth paying for. While the bar was a `.nonactivatingPanel`
/// its buttons fired on the first click no matter which app was in front — the
/// panel never took activation, so there was no activation click to swallow. An
/// ORDINARY window works the other way: the first click on an inactive app's
/// window activates the app, and by default the control under the cursor never
/// sees it. On a compact control bar that reads as "the record button needs two
/// clicks". `acceptsFirstMouse` restores the one-click feel while keeping the
/// activation the verdict asked for.
private final class CommandBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CommandBarHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        let hosting = CommandBarHostingView(rootView: rootView)
        // Set HERE, not only on the controller: substituting the view in
        // `loadView` is what lets the subclass exist at all, and the controller's
        // own `sizingOptions` is not guaranteed to reach a view it did not make.
        // Getting this wrong would let SwiftUI drive the window size and fight
        // every frame the morph geometry computes — so it is pinned on the object
        // that actually reports the size. Round 13 moved the value itself into
        // `WindowSizing`, where the 4.5.0 crash that this line was always
        // protecting against is written down.
        WindowSizing.pin(hosting)
        view = hosting
    }
}

// MARK: - Delegate

/// Persists the panel's position as the user drags it (the panel is
/// `isMovableByWindowBackground`, so moves happen without any code of ours
/// running). WHICH anchor a drag updates depends on the current surface — a
/// dragged recording pill must not clobber the bar's saved spot — so the
/// decision lives on the manager.
private final class CommandBarPanelDelegate: NSObject, NSWindowDelegate {
    weak var manager: CommandBarWindowManager?

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let logical = MorphGeometry.logicalFrame(forPanel: window.frame)
        // NSWindowDelegate callbacks arrive on the main thread.
        MainActor.assumeIsolated {
            manager?.panelWasDragged(toLogicalFrame: logical)
        }
    }
}

// MARK: - Manager

/// Owns the command-bar panel and morphs it between surfaces (bar / bar+drawer /
/// recording pill). Since round 12 it also owns the panel's PERSONALITY: the bar
/// and its drawers are an ordinary window, only the recording pill floats above
/// everything and hides from screen capture (see `windowTraits`). There is no
/// main window any more — phase 7 removed it.
@Observable @MainActor
final class CommandBarWindowManager {
    typealias Surface = CommandBarSurface
    typealias DrawerTab = CommandBarDrawerTab

    // MARK: - Window personality (round 12)

    /// The window traits one surface demands — see `CommandBarPanel`'s docs for
    /// the verdict behind the split. A plain value so the policy is a TEST, not
    /// a promise: getting `sharingType` wrong on the pill would put Tracer's own
    /// controls into the user's recording.
    struct WindowTraits: Equatable {
        let level: NSWindow.Level
        let sharingType: NSWindow.SharingType
        let collectionBehavior: NSWindow.CollectionBehavior
        /// `.nonactivatingPanel` in the style mask: clicks do not activate the app.
        let nonactivating: Bool
        /// NSPanel's "a click only makes me key if something inside needs typing".
        let becomesKeyOnlyIfNeeded: Bool
    }

    /// Surface → window personality. Two rows, and the difference between them is
    /// the whole of round 12:
    ///
    /// - The RECORDING PILL is the control surface of a live take. It floats above
    ///   everything (you must be able to stop a take from inside any app), joins
    ///   every Space (the take follows the user), refuses to activate the app on a
    ///   click (focus belongs to whatever is being recorded), and is invisible to
    ///   screen capture.
    /// - Everything else is an ORDINARY WINDOW: normal level, its own Space, a
    ///   click activates the app, and it is visible to screenshots and recordings.
    ///
    /// `takeLive` forces the never-captured half even on the bar. The screen
    /// stream starts — and the writer ARMS — several awaits before
    /// `RecordingManager.isRecording` flips, so a panel that only hid itself on
    /// the pill morph would land in the opening frames of every recording. The
    /// flag closes that head; the surface rule owns the rest of the take.
    nonisolated static func windowTraits(for surface: Surface, takeLive: Bool) -> WindowTraits {
        if surface == .recordingPill {
            return WindowTraits(
                level: .floating,
                sharingType: .none,
                collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary],
                nonactivating: true,
                becomesKeyOnlyIfNeeded: true
            )
        }
        return WindowTraits(
            level: .normal,
            sharingType: takeLive ? NSWindow.SharingType.none : .readOnly,
            // No `canJoinAllSpaces` and no `fullScreenAuxiliary`: an ordinary
            // window lives on its own Space and does not hover over a fullscreen
            // app. That is exactly the "стоп бути завжди поверх" the verdict asked for.
            collectionBehavior: [],
            nonactivating: false,
            becomesKeyOnlyIfNeeded: false
        )
    }

    /// True while a take is live OR being prepared (see `windowTraits`).
    ///
    /// DERIVED, never cached — and that is a bug fix, not a preference. A stored
    /// flag has exactly one writer, the SwiftUI root's `.onChange`, and that root
    /// dies with the panel: "Hide pill (recording continues)" tears the panel
    /// down mid-take, so a cached `true` would never be cleared, and the next
    /// tray → "Settings…" would find `takeLive` still true and refuse the drawer
    /// its keyboard — the round-9 «⌘, · Esc не працює» bug, resurrected. The
    /// mirror case is just as bad: a take started from the tray while the bar was
    /// hidden would leave a cached `false` and bring the bar up capturable over a
    /// live stream. Reading the recorder at the moment the traits are applied has
    /// no stale state to go wrong.
    private var takeIsLive: Bool {
        guard let recorder = appState?.recordingManager else { return false }
        return recorder.isStarting || recorder.isRecording
    }

    /// The surface currently shown. The SwiftUI root switches on this.
    private(set) var surface: Surface = .bar

    /// Extra logical height under the bar while the storage banner is visible
    /// (`MorphGeometry.storageBannerExtent`, or 0). Only `.bar` renders the banner;
    /// the geometry ignores the value on every other surface.
    private(set) var bannerExtent: CGFloat = 0

    /// Bumped when Esc lands on the recording pill. The pill view observes this and
    /// opens its discard-confirmation popover (round 4) — a counter (not a Bool) so
    /// every press registers regardless of the previous value.
    private(set) var pillEscSignal = 0

    /// Extra logical width of the recording pill past its 341-pt base (round 3):
    /// the pill panel resizes DYNAMICALLY to its SwiftUI content — like the toast —
    /// for transient content the mockup doesn't draw (a 100+ minute timer wider
    /// than its 57-pt slot). Reported by the pill view via
    /// `setRecordingPillContentWidth`; only `.recordingPill` frames consume it.
    private(set) var pillExtraWidth: CGFloat = 0

    /// Extra logical width of the BAR ROW for the update chip: exactly
    /// `MorphGeometry.updateChipExtent` while the chip exists, 0 otherwise —
    /// two values, nothing in between (round 9: the chip's hover unroll lives
    /// inside a reserved slot and never reaches the panel).
    private(set) var chipExtraWidth: CGFloat = 0

    /// True between the chip LEAVING and the deferred frame snap — the drawer
    /// close trick: the chip's exit spring plays inside the still-wide panel
    /// (the spare strip is transparent), and the frame snaps down only once
    /// the spring has settled, changing no visible pixel. Snapping in the same
    /// tick would clip the exit animation and yank the close cross left.
    private var pendingChipShrinkSnap = false

    /// updateChip spring (response 0.34) settles ≈ 0.55s; 0.6 snaps with margin.
    private static let chipShrinkSnapDelay: TimeInterval = 0.6

    /// Whether the currently open drawer unfolds ABOVE the bar (verdict 26.08:
    /// upward ONLY when the drawer cannot fit below — `MorphGeometry.
    /// drawerOpensUpward`). The SwiftUI root reads this to flip the stack order
    /// and the pin edge. On close it stays TRUE until the deferred frame snap
    /// (round 5b): the bottom pin is what keeps the bar pixel-still while the
    /// drawer fades out above it inside the still-large panel.
    private(set) var drawerOpensUp = false

    /// True between a drawer close and its deferred frame snap (round 5b): the
    /// surface is already `.bar` but the panel deliberately still wears the
    /// drawer-sized frame so the removal fade + the Liquid Glass dematerialize
    /// can play out un-clipped. Anything that would reframe or persist anchors
    /// from the oversized frame must check this first.
    private var pendingDrawerCloseSnap = false

    /// The tab of a drawer mid-CLOSE (round 5c), nil otherwise. The closing
    /// drawer STAYS IN THE SWIFTUI TREE — still occupying its layout slot in
    /// the held panel frame — while its opacity animates to 0; only the
    /// deferred snap removes it, when nothing of it is visible any more.
    ///
    /// Why not a removal transition: burst-proven twice. A bare state change
    /// yanks the removed subtree in ONE frame (a transition's attached
    /// animation drives insertions, not removals), and putting the fade into
    /// the transaction animates the LAYOUT REFLOW too — the dying drawer
    /// slides across the bar's face while fading. Keeping the node in layout
    /// is the only variant where the drawer dissolves exactly in place.
    private(set) var closingDrawerTab: DrawerTab?

    /// How long the panel keeps the drawer-sized frame after a close (round 5b).
    /// Harness-measured: the 0.15s `drawerFade` plus the glass dematerialize
    /// tail end ~0.28s after the morph; 0.35s snaps with margin, and a snap that
    /// late changes no visible pixel (burst-verified, shots r5a-*).
    private static let drawerCloseSnapDelay: TimeInterval = 0.35

    private var panel: CommandBarPanel?
    private let panelDelegate = CommandBarPanelDelegate()
    private weak var appState: AppState?

    /// Logical TOP-LEFT of the BAR — the stable anchor every morph is computed
    /// from. Tracked explicitly (not re-derived from the panel frame) because an
    /// upward-opened drawer and the recording pill both put the panel somewhere
    /// the bar is NOT, and the bar must come back to exactly this point.
    private var barAnchor: CGPoint?

    // MARK: Persisted positions

    // The stored points are LOGICAL TOP-LEFT anchors (AppKit screen coordinates,
    // so top-left = (minX, maxY)). NSPoint isn't UserDefaults-storable; x/y are
    // two Doubles. The bar and the recording pill persist separately: the pill
    // has its own perch (top-center by default, wherever the user dragged it
    // afterwards — the camera bubble's contract), and neither position may
    // clobber the other.
    private static let anchorXKey = "commandBarOriginX"
    private static let anchorYKey = "commandBarOriginY"
    private static let pillAnchorXKey = "recordingPillOriginX"
    private static let pillAnchorYKey = "recordingPillOriginY"

    nonisolated static func saveAnchor(_ anchor: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(anchor.x), forKey: anchorXKey)
        defaults.set(Double(anchor.y), forKey: anchorYKey)
    }

    nonisolated static func savedAnchor() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: anchorXKey) != nil,
              defaults.object(forKey: anchorYKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: anchorXKey),
                       y: defaults.double(forKey: anchorYKey))
    }

    nonisolated static func savePillAnchor(_ anchor: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(anchor.x), forKey: pillAnchorXKey)
        defaults.set(Double(anchor.y), forKey: pillAnchorYKey)
    }

    nonisolated static func savedPillAnchor() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: pillAnchorXKey) != nil,
              defaults.object(forKey: pillAnchorYKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: pillAnchorXKey),
                       y: defaults.double(forKey: pillAnchorYKey))
    }

    /// The anchor a surface should be framed from: the pill has its own perch;
    /// everything else hangs off the bar anchor (lazily seeded on first use).
    /// Parameterized (round 5c) because a flight needs the TARGET surface's
    /// anchor while `surface` still holds the source.
    private func anchorFor(surface: Surface, visible: CGRect) -> CGPoint {
        if surface == .recordingPill {
            return Self.savedPillAnchor() ?? MorphGeometry.recordingPillTopLeft(visible: visible)
        }
        if let barAnchor { return barAnchor }
        let size = MorphGeometry.size(of: .bar, bannerHeight: bannerExtent)
        let origin = MorphGeometry.initialOrigin(for: size, visible: visible)
        let anchor = CGPoint(x: origin.x, y: origin.y + size.height)
        barAnchor = anchor
        return anchor
    }

    private func anchorForCurrentSurface(visible: CGRect) -> CGPoint {
        anchorFor(surface: surface, visible: visible)
    }

    // MARK: Lifecycle

    func show(appState: AppState) {
        self.appState = appState

        // A recording can already be running when the bar comes (back) up — started
        // from the tray while the panel was closed. Come up as the matching surface,
        // because the root's isRecording observer only fires on CHANGES.
        if appState.recordingManager.isRecording {
            surface = .recordingPill
        } else if surface == .recordingPill {
            surface = .bar
        }

        if panel == nil {
            let host = CommandBarHostingController(
                rootView: CommandBarRootView(appState: appState, manager: self)
            )
            // The panel's size is driven by morph(to:), never by the SwiftUI fitting size.
            WindowSizing.pin(host)

            let newPanel = CommandBarPanel(contentRect: .zero)
            newPanel.contentViewController = host
            panelDelegate.manager = self
            newPanel.delegate = panelDelegate
            // Esc closes an open drawer, and on the recording pill opens the inline
            // discard confirmation. The panel must be key for Esc to arrive at all:
            // on the bar that comes with the click that opened the drawer, and the
            // pill — deliberately never key — relies on the drawer path instead.
            // On the bare bar: nothing.
            newPanel.onEsc = { [weak self] in
                guard let self else { return }
                switch self.surface {
                case .barWithDrawer:
                    self.morph(to: .bar)
                case .recordingPill:
                    self.pillEscSignal += 1
                case .bar:
                    break
                }
            }
            // ⌘, — the shortcut the Settings drawer's header advertises. Toggles
            // the drawer; inert mid-recording (the pill has no drawers).
            newPanel.onCmdComma = { [weak self] in
                guard let self, let target = Self.cmdCommaTarget(from: self.surface) else { return }
                self.morph(to: target)
            }
            panel = newPanel
        }
        guard let panel else { return }

        let visible = currentVisibleFrame()
        if barAnchor == nil {
            // savedAnchor may be stale (disconnected display) — targetFrame
            // re-clamps below, so it self-corrects instead of landing off-screen.
            barAnchor = Self.savedAnchor()
        }
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: surface, bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth, chipExtraWidth: chipExtraWidth, visible: visible
        )
        // A re-show mid-flight (round 5c) supersedes the flight: zero offset +
        // target frame in one transaction, content lands in place.
        cancelFlight()
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)

        applyPanelAppearance()
        // Round 12: dress the window for the surface it is about to show BEFORE it
        // is ordered in — a panel coming up as the pill (a take started while the
        // bar was hidden) must already be `sharingType = .none` on its first frame.
        applyWindowTraits(for: surface)
        panel.orderFrontRegardless()
        // Round 9: a panel that comes up already wearing a drawer takes the
        // keyboard right away, so Esc works without a click. Bare bar / pill:
        // never. In practice `dismissPanel` resets the surface to `.bar`, so the
        // tray's "Settings…" arrives here as a bar and the drawer's own `morph`
        // does the asking a beat later — this call is the belt for any future
        // door that shows a drawer directly.
        takeKeyboard(for: surface)
        // Round 6 REGRESSION FIX («після апдейту авто не працює, поки не
        // перемкнеш тему»): everything above ran while the panel was still
        // ordered OUT — `applyPanelAppearance()` → `syncBackdropMonitor()` saw
        // `panel.isVisible == false` and STOPPED the monitor instead of starting
        // it, and the root view's `.onChange(of: appTheme, initial: true)` fires
        // during the first layout pass, also pre-front. So a fresh launch with
        // Auto never sampled the backdrop; a manual theme round-trip "fixed" it
        // only because that onChange runs against an already-visible panel.
        // One more sync AFTER orderFront is the whole cure: the panel is
        // visible now, so Auto actually starts its monitor.
        syncBackdropMonitor()
    }

    /// Hides the bar — the app keeps running in the menu bar (verdict 25.08: the
    /// close button hides, it does NOT quit). A no-op mid-recording: the pill is
    /// the only control surface of a live take and has no close button anyway —
    /// its OWN way out is `hideRecordingPill()` below.
    func hide() {
        // `takeIsLive`, not `isRecording`: the guard has to cover the START HEAD
        // too. Between the record button and `isRecording` flipping there are
        // several awaits, and a close click landing in that window used to tear
        // the panel down before the pill ever appeared — leaving a running take
        // with no visible control surface at all.
        guard !takeIsLive else { return }
        dismissPanel()
    }

    /// The recording pill's "hide" button (round 3): sends the panel away while
    /// the take KEEPS recording — deliberately bypassing `hide()`'s mid-recording
    /// guard, which exists to stop the bar's close door, not this one. The tray
    /// keeps the red-dot timer; a left tray click (or the tray menu's "Show
    /// recording pill") brings the pill back — `show()` comes up as the pill
    /// surface whenever a recording is live.
    func hideRecordingPill() {
        guard surface == .recordingPill else { return }
        dismissPanel()
    }

    /// Whether the panel is currently on screen — the tray's click routing needs
    /// this to tell "stop the take" from "bring the hidden pill back".
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Shared teardown of `hide()` / `hideRecordingPill()`: persist the anchor of
    /// whatever surface is up, then drop the panel (a later `show()` rebuilds it).
    private func dismissPanel() {
        backdropMonitor.stop()   // no panel → nothing to sample under (4.1.0)
        if let panel {
            if pendingDrawerCloseSnap || flightActive {
                // Mid-close (round 5b) or mid-flight (round 5c): the surface
                // state is already final but the panel deliberately wears an
                // oversized frame (the held drawer frame / the flight union) —
                // deriving an anchor from THAT frame would corrupt the saved
                // position. The correct anchor was already persisted (on drawer
                // open / at flight lift-off); there is nothing new to save.
                pendingDrawerCloseSnap = false
                closingDrawerTab = nil
                drawerOpensUp = false
                cancelFlight()
            } else {
                let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
                // Intent, not the clamped resting frame — a bar pushed left by
                // the chip's slot near the screen edge must not save that shove
                // (round 9 review). A drag has already persisted its own truth.
                persistAnchor(
                    forLogicalFrame: logical,
                    intended: surface == .recordingPill ? Self.savedPillAnchor() : barAnchor
                )
            }
            panel.orderOut(nil)
        }
        panel = nil
        // Round 9 review: a bar hidden WITH a drawer open used to keep
        // `.barWithDrawer` in `surface`, so the next `show()` came up wearing
        // the drawer and — since round 9 — took the keyboard for it, i.e. a
        // tray click activated the app. The bar always comes back closed and
        // quiet; a recording re-entry still overrides this in `show()`.
        pendingChipShrinkSnap = false
        if surface != .recordingPill { surface = .bar }
    }

    /// The pill view reports its laid-out width here (round 3): anything past the
    /// 341-pt base becomes `pillExtraWidth` and the panel grows to the RIGHT of
    /// the pill's held top-left anchor (the stop button at the leading edge must
    /// not move under an approaching cursor — see `MorphGeometry.targetFrame`).
    /// Idempotent per width, so the resize→relayout→report cycle settles.
    func setRecordingPillContentWidth(_ width: CGFloat) {
        let extra = max(0, width - Theme.Metrics.recordingPillSize.width)
        guard extra != pillExtraWidth else { return }
        pillExtraWidth = extra
        guard surface == .recordingPill else { return }
        // The pill's width growth stays animated (round 5 touches only drawers/
        // banner): it is part of the pill's own motion language, and the timer
        // crossing its slot is a once-per-take event.
        reframe(animated: true)
    }

    /// Whether a surface switch animates the morph (round 5, вердикт з
    /// бойової 4.0.0: «хай плашка буде спокійною»). Only the recording-pill
    /// morphs fly — the pill travels to its perch and back, on the compositor
    /// flight since round 5c (`beginFlight`). Drawer open/close SNAPS: moving
    /// the panel frame tick-by-tick while the SwiftUI root re-lays out inside
    /// it is exactly what read as the bar «здригається» — the bar must sit
    /// pixel-still, so the panel jumps to its final frame in one tick and only
    /// the drawer's own opacity fades (`Theme.Anim.drawerFade`). Pure and
    /// static so the policy is testable without a panel.
    nonisolated static func morphAnimates(from old: Surface, to new: Surface) -> Bool {
        old == .recordingPill || new == .recordingPill
    }

    // MARK: Keyboard reach (round 9 — making the drawer's hint true)

    /// What ⌘, should do from a surface — nil means "ignore the key". Pure so
    /// the toggle is a test rather than a promise: the Settings drawer CLOSES
    /// on a second ⌘, (it is a toggle, exactly as the header hint implies),
    /// the Gallery drawer switches to Settings, and mid-take nothing happens
    /// (the pill has no drawers).
    nonisolated static func cmdCommaTarget(from surface: Surface) -> Surface? {
        switch surface {
        case .barWithDrawer(.settings): return .bar
        case .bar, .barWithDrawer: return .barWithDrawer(.settings)
        case .recordingPill: return nil
        }
    }

    /// Whether a surface wants the panel to hold the KEYBOARD. Only drawers do:
    /// they are the only surface with keyboard affordances (Esc closes, ⌘,
    /// toggles — the Settings header advertises both). The bare bar and the
    /// recording pill never take the keyboard: there is nothing to type into,
    /// and mid-take stealing focus would be hostile.
    nonisolated static func surfaceWantsKeyboard(_ surface: Surface) -> Bool {
        if case .barWithDrawer = surface { return true }
        return false
    }

    /// Whether the panel should reach for the keyboard, given the surface it is
    /// about to wear and whether a take is live. Pure, because the second half is
    /// a SAFETY invariant, not a nicety: nothing may activate this app while the
    /// user is recording — stealing focus would land in their video.
    nonisolated static func shouldTakeKeyboard(for surface: Surface, takeLive: Bool) -> Bool {
        !takeLive && surfaceWantsKeyboard(surface)
    }

    /// Round 9 (boss's verdict on 4.4.1: «підказка ⌘, · Esc to close не працює»)
    /// — SIMPLIFIED by round 12.
    ///
    /// The old problem was that this panel was permanently nonactivating with
    /// `becomesKeyOnlyIfNeeded`, so until the user clicked INSIDE the drawer the
    /// panel was not key and the header advertised shortcuts that did not exist.
    /// Round 12 dissolves most of that: on the bar and its drawers the panel is
    /// now an ordinary window, so a plain CLICK makes it key and Esc / ⌘, work
    /// from the first second without any trickery.
    ///
    /// What is still needed is the door that opens a drawer WITHOUT touching the
    /// panel — the tray's "Settings…" on a hidden bar. There the app can be
    /// inactive, and keyboard events only ever reach the key window of the ACTIVE
    /// app, so activation is the honest (and only) way in. It stays scoped to
    /// drawers, which never open by themselves.
    ///
    /// What ROUND 12 DELETED is the counterpart: `releaseKeyboardIfTaken()` and
    /// its `NSApp.deactivate()`. Two reasons, either one sufficient. (1) It is now
    /// actively harmful: the bar sits at `.normal` level, so deactivating the app
    /// drops it behind whatever is in front — close the drawer and the bar
    /// disappears under Chrome. (2) It is no longer ours to give back: the app is
    /// active because the user CLICKED our window, exactly like any other app, and
    /// no ordinary Mac app deactivates itself when you close a panel. Losing it
    /// also retires the whole `shouldReleaseKeyboard` / Sparkle "dead button"
    /// hazard class that round 9 had to reason its way around.
    private func takeKeyboard(for surface: Surface) {
        guard Self.shouldTakeKeyboard(for: surface, takeLive: takeIsLive) else { return }
        guard let panel, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Window personality (round 12)

    /// Dresses the live panel for `surface`. Called before every surface swap and
    /// whenever the take state changes.
    private func applyWindowTraits(for surface: Surface) {
        guard let panel else { return }
        let levelChanged = panel.apply(Self.windowTraits(for: surface, takeLive: takeIsLive))
        // A level change re-sorts the window across the whole z-order, and the
        // demotion is the one that bites: the pill lived in the floating band, so
        // the bar it turns back into would land UNDER whatever app is in front and
        // read as "Tracer vanished after my recording". Ordering it front once puts
        // the returning bar where the user can see it WITHOUT taking focus — and
        // from that moment it behaves like any window and yields to the next app
        // the user clicks, which is the entire point of the verdict.
        if levelChanged, panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The SwiftUI root pokes this when `isStarting || isRecording` changes. It
    /// carries no value on purpose — the state is read from the recorder itself
    /// (`takeIsLive`); this is only the "look again now" signal, so that the bar
    /// leaves the capture at the head of a take without waiting for a morph.
    func refreshWindowTraits() {
        applyWindowTraits(for: surface)
    }

    /// Switches the panel to another surface. The BAR anchor stays the stable
    /// reference: the pill flies to its own perch and back, and an upward drawer
    /// grows above the stationary bar (see `MorphGeometry.targetFrame`).
    func morph(to newSurface: Surface) {
        guard surface != newSurface else { return }
        // ROUND 12, AND IT GOES FIRST: the window's personality follows the
        // surface, and the pill's half of it must be in place BEFORE the pill
        // paints a single frame — that is what keeps Tracer's own controls out of
        // the user's recording. `morph` has several exit paths and none of this
        // depends on the resulting frame, so it is settled up front.
        applyWindowTraits(for: newSurface)
        // Round 9: a drawer takes the keyboard the moment it opens, so Esc and ⌘,
        // work without a preliminary click. Only on the OPENING edge — a tab
        // switch is already ours. (The hand-back half died in round 12; see
        // `takeKeyboard`.)
        if !Self.surfaceWantsKeyboard(surface), Self.surfaceWantsKeyboard(newSurface) {
            takeKeyboard(for: newSurface)
        }
        // Any surface change supersedes a drawer close still waiting for its
        // frame snap — the new morph reframes for itself. A half-faded closing
        // drawer is dropped on the spot (a ≤0.15s window, user-interrupted).
        let hadPendingSnap = pendingDrawerCloseSnap
        pendingDrawerCloseSnap = false
        closingDrawerTab = nil
        let animated = Self.morphAnimates(from: surface, to: newSurface)
        let closingDrawer: Bool
        if case .barWithDrawer = surface, newSurface == .bar {
            closingDrawer = true
        } else {
            closingDrawer = false
        }
        if newSurface == .recordingPill {
            // A fresh take starts at the base width; the mounted pill re-reports
            // its actual width immediately (a stale extra from the previous take's
            // long timer must not flash on the new pill).
            pillExtraWidth = 0
        }
        if case .barWithDrawer = newSurface {
            // Drawers only ever open from the bar (the pill has none), so the
            // bar anchor is the reference for the direction rule.
            let visible = currentVisibleFrame(for: panel)
            var anchor = anchorForCurrentSurface(visible: visible)
            if surface == .recordingPill { anchor = barAnchor ?? anchor }
            drawerOpensUp = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        }

        if animated, let panel, panel.isVisible {
            if hadPendingSnap {
                // Mid close-hold the bar sits at the BOTTOM of a deliberately
                // oversized panel, but the flight's offset math assumes the
                // content fills the logical frame — complete the deferred snap
                // first (clipping the last beats of the drawer fade under a
                // starting recording is fine; the old frame animation clipped
                // it the same way).
                reframe(animated: false)
                drawerOpensUp = false
            }
            // Round 5c compositor flight (verdict 26.08, «рідні анімації …
            // мають більше fps»). ORDER MATTERS, burst-caught twice:
            // 1. The flight's coordinate base — the offset jump and the union
            //    frame — must commit BEFORE the branch swap: an outgoing branch
            //    freezes at the attribute values of the PREVIOUS commit, so a
            //    swap-first ordering paints the dying surface one frame at the
            //    union's top-left corner.
            // 2. The swap itself must ride the same spring the offset flies on:
            //    a transition's attached animation drives insertions, but a
            //    REMOVAL only animates when the transaction of the state change
            //    carries the animation — a bare `surface = …` yanks the old
            //    surface in a single frame.
            let flight = beginFlight(toSurface: newSurface, panel: panel)
            withAnimation(Theme.Anim.surface) { surface = newSurface }
            persistAnchor(forLogicalFrame: flight.target, intended: flight.intended)
            backdropMonitor.sampleSoon()
            if newSurface == .bar { drawerOpensUp = false }
            return
        }

        if closingDrawer {
            // Round 5c: the closing drawer stays IN the tree and IN layout
            // (`closingDrawerTab`) while its opacity animates to 0 — the fade
            // lives in the TRANSACTION of this state change. See the property
            // docs for why a removal transition cannot do this job.
            if case .barWithDrawer(let tab) = surface {
                withAnimation(Theme.Anim.drawerFade) {
                    closingDrawerTab = tab
                    surface = newSurface
                }
            } else {
                surface = newSurface
            }
        } else {
            surface = newSurface
        }

        if closingDrawer {
            // Round 5b (verdict 26.08, «анімація рвана» when the up-drawer
            // closes): the close is symmetric to the open. The drawer fades out
            // IN PLACE — the panel keeps the drawer-sized frame and the pin edge
            // keeps the bar pixel-still — because snapping the frame in the same
            // tick would CLIP the removal fade and the ~150ms Liquid Glass
            // dematerialize that follows it (on an upward drawer that clipped,
            // dying glass collapsed visibly across the bar's face). The frame
            // snap runs after `drawerCloseSnapDelay`, when nothing visible is
            // left to clip — burst-proven invisible (shots r5a-*).
            pendingDrawerCloseSnap = true
            scheduleDrawerCloseSnap(after: Self.drawerCloseSnapDelay)
            return
        }

        reframe(animated: false)
        if newSurface == .bar {
            drawerOpensUp = false
        }
    }

    /// The drawer close's deferred frame snap. Split out (round 9 review)
    /// because it can RE-ARM itself: when the update chip is also mid-exit its
    /// longer deferral must own the reframe (snapping here would clip the
    /// chip's collapse), and rather than bailing out — which could strand the
    /// panel at drawer size if that chip snap were then cancelled by the chip
    /// coming straight back — this waits out the remaining time and tries
    /// again. Whoever runs last does the single reframe; the snap always
    /// happens exactly once.
    private func scheduleDrawerCloseSnap(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingDrawerCloseSnap else { return }
                guard self.surface == .bar else {
                    self.pendingDrawerCloseSnap = false
                    return
                }
                if self.pendingChipShrinkSnap {
                    // The chip's exit spring is still running inside this same
                    // oversized panel — come back when it has settled.
                    self.scheduleDrawerCloseSnap(
                        after: Self.chipShrinkSnapDelay - Self.drawerCloseSnapDelay
                    )
                    return
                }
                self.pendingDrawerCloseSnap = false
                // The drawer leaves the tree only NOW, at opacity 0 — its
                // removal (and the glass teardown) has nothing visible left.
                self.closingDrawerTab = nil
                self.reframe(animated: false)
                // Back to the default top pin only once the bar-sized panel
                // is in place — content fills it exactly, so the flip cannot
                // move a pixel.
                self.drawerOpensUp = false
            }
        }
    }

    /// Shows/hides the storage banner under the bar, resizing the panel in place.
    /// Called by the SwiftUI root when the quota level crosses the threshold —
    /// including mid-session, right after an upload refreshes used/allocated.
    /// Snaps, never animates (round 5): the banner rides under the resting bar,
    /// and the bar must not stir — the banner's own fade is all the motion.
    func setStorageBannerVisible(_ visible: Bool) {
        let newExtent: CGFloat = visible ? MorphGeometry.storageBannerExtent : 0
        guard newExtent != bannerExtent else { return }
        bannerExtent = newExtent
        // Mid drawer-close (round 5b) the extent is recorded but the panel is
        // deliberately oversized for the removal fade — the deferred snap will
        // apply it; reframing NOW would clip the fade.
        guard !pendingDrawerCloseSnap else { return }
        reframe(animated: false)
    }

    /// The bar row reports whether it currently carries the update chip
    /// (round 9 — a BOOL, not a width: the only two widths are "no chip" and
    /// "chip with its full reserved slot"; a hover cannot produce a third).
    /// The panel follows the drawer-close recipe, and in both directions the
    /// bar itself never stirs:
    /// - APPEARS: the frame widens in the same tick (the new strip is
    ///   transparent — the row's content is still narrow), then the row's own
    ///   spring grows the glass into it. Compositor-path growth, like the pill
    ///   flight: no tick-by-tick window resize.
    /// - LEAVES: the row springs down first inside the still-wide panel; the
    ///   frame snap waits out the spring (`chipShrinkSnapDelay`) and then
    ///   changes no visible pixel.
    func setUpdateChipSlotVisible(_ visible: Bool) {
        let target = visible ? MorphGeometry.updateChipExtent : 0
        guard target != chipExtraWidth else { return }
        let growing = target > chipExtraWidth
        chipExtraWidth = target
        // Mid-flight (bar→pill) the union frame rules; the pill ignores chip
        // width and the return morph reframes from scratch.
        guard !flightActive, surface != .recordingPill else { return }
        if growing {
            pendingChipShrinkSnap = false
            // Mid drawer-close the panel is deliberately oversized for the
            // removal fade — reframing now would clip it, and the deferred
            // drawer snap picks the new width up within its 0.35s anyway.
            guard !pendingDrawerCloseSnap else { return }
            reframe(animated: false)
            return
        }
        // SHRINK. Round 9 review: this used to bail out under
        // `pendingDrawerCloseSnap` WITHOUT arming its own snap, so a drawer
        // closing within ~0.2s of the chip leaving got its 0.35s snap applied
        // to a chip whose exit spring still had 0.25s to run — the chip's
        // collapse was clipped. Both deferrals are armed now and the LAST one
        // does the single reframe (see the drawer snap's guard).
        pendingChipShrinkSnap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chipShrinkSnapDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingChipShrinkSnap else { return }
                self.pendingChipShrinkSnap = false
                guard !self.flightActive, self.surface != .recordingPill else { return }
                // The drawer's own snap fires first (0.35 < 0.6) and, seeing
                // this flag, left the frame alone — so this one reframe lands
                // both the width and the height.
                self.reframe(animated: false)
                // Only the bar surface may clear the drawer's bookkeeping. With a
                // drawer still open — turning off "Preview update button" from an
                // upward-opened Settings drawer is the live path — clearing
                // `drawerOpensUp` here would flip the drawer under the bar inside
                // a frame that is still the upward one, throwing the bar up by the
                // drawer's height. Same gate the drawer's own snap carries.
                guard self.surface == .bar else { return }
                self.pendingDrawerCloseSnap = false
                self.closingDrawerTab = nil
                self.drawerOpensUp = false
            }
        }
    }

    /// Re-derives the panel frame for the current surface + banner extent from the
    /// surface's anchor (bar anchor, or the pill's own perch). Shared by morphs
    /// and banner visibility flips.
    ///
    /// `animated` (round 5c, verdict 26.08 — «рідні анімації … мають більше fps»):
    /// pill flights are COMPOSITOR-driven. The previous NSAnimationContext frame
    /// animation ticked a window-server resize on a main-thread timer: every tick
    /// re-laid-out the hosting view and re-sampled the Liquid Glass at a new size,
    /// and the tick rate never exceeds 60 — half the shef's ProMotion display.
    /// Now the panel takes the UNION of both endpoint frames in ONE tick and the
    /// CONTENT flies inside it on an animated SwiftUI offset — a per-frame layer
    /// transform, no re-layout, running at the display's native rate. When the
    /// spring settles, the frame snaps to the target; the content already sits
    /// exactly there, so the snap changes no visible pixel (burst-proven,
    /// shots r5c-*). Drawer/banner reframes pass `false` and snap in one tick —
    /// see `morphAnimates` for why. Animation is also skipped while the panel is
    /// off screen — animating an invisible window only delays it.
    private func reframe(animated: Bool) {
        guard let panel else { return }
        if animated, panel.isVisible {
            // Same-surface animated reframe (the pill widening under a long
            // timer): starts — or retargets — a flight toward the fresh target.
            let flight = beginFlight(toSurface: surface, panel: panel)
            persistAnchor(forLogicalFrame: flight.target, intended: flight.intended)
            backdropMonitor.sampleSoon()
            return
        }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: surface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            chipExtraWidth: chipExtraWidth,
            visible: visible
        )
        // A snap reframe supersedes any flight still in the air: zero the
        // offset in the same transaction as the frame jump, so the content
        // lands exactly in the new frame (drawer opened within ~0.3s of a
        // pill landing, say).
        cancelFlight()
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
        persistAnchor(forLogicalFrame: target, intended: anchor)
        // The surface now sits over different desktop real estate — let the Auto
        // theme re-judge it (debounced; a no-op while the monitor sleeps).
        backdropMonitor.sampleSoon()
    }

    // MARK: Compositor flight (round 5c)

    /// Content displacement while a flight is in the air: the panel wears the
    /// union frame, the pin is top-leading, and the CONTENT sits at
    /// `contentOffset(of: <its logical frame>, in: <union>)` — animated by the
    /// `Theme.Anim.surface` spring from the source position to the target's.
    /// Zero between flights. The SwiftUI root applies it verbatim.
    private(set) var flightOffset: CGSize = .zero

    /// True from lift-off to the settle snap. The root reads it to force the
    /// top-leading pin during a flight (the offset's coordinate base) even when
    /// a lingering `drawerOpensUp` would pin bottom.
    private(set) var flightActive = false

    /// Orphans stale flight callbacks: every lift-off, retarget and cancel bumps
    /// it, and completions compare before touching state.
    private var flightGeneration = 0

    /// Starts (or retargets) the compositor flight toward `toSurface`'s target
    /// frame, computed from that surface's own anchor. Returns the target so
    /// the caller can persist it. Does NOT touch `surface` — the caller swaps
    /// it right after, inside the spring transaction (see `morph`).
    ///
    /// Lift-off is one atomic beat: `flightOffset` is jumped (animation
    /// explicitly disabled) to the content's CURRENT position inside the union
    /// and the panel takes the union frame — same commit, so the content does
    /// not move on screen. The spring launches a runloop turn later: writing
    /// the same property twice in one turn coalesces into a plain jump
    /// (burst-proven — the flight degenerated into two fades in place). A
    /// retarget mid-flight lets the spring continue from its live presentation
    /// value — valid as long as the union's top-left (the offset's coordinate
    /// base) stays put; when a retarget would move the base (pill widening
    /// against the screen edge — ultra-rare), the flight snaps out instead.
    /// Returns the target frame AND the anchor it was computed from — the
    /// caller persists the INTENT, never the clamped frame (round 9 review).
    @discardableResult
    private func beginFlight(
        toSurface: Surface, panel: CommandBarPanel
    ) -> (target: CGRect, intended: CGPoint) {
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorFor(surface: toSurface, visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: toSurface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            chipExtraWidth: chipExtraWidth,
            visible: visible
        )
        let current = MorphGeometry.logicalFrame(forPanel: panel.frame)

        if flightActive {
            guard MorphGeometry.unionKeepsTopLeft(current: current, adding: target) else {
                cancelFlight()
                panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
                return (target, anchor)
            }
            let union = current.union(target)
            if union != current {
                // Grows right/down only — the base corner holds, nothing moves.
                panel.setFrame(MorphGeometry.panelFrame(forLogical: union), display: true)
            }
            launchFlightSpring(toward: MorphGeometry.contentOffset(of: target, in: union))
            return (target, anchor)
        }

        let union = current.union(target)
        flightActive = true
        isAnimatingReframe = true
        // The base jump must not animate — and must land BEFORE the union
        // frame's layout pass, so that pass already draws the content where
        // it visually is.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            flightOffset = MorphGeometry.contentOffset(of: current, in: union)
        }
        panel.setFrame(MorphGeometry.panelFrame(forLogical: union), display: true)
        let destination = MorphGeometry.contentOffset(of: target, in: union)
        flightGeneration += 1
        let generation = flightGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.flightActive, self.flightGeneration == generation else { return }
            self.launchFlightSpring(toward: destination)
        }
        return (target, anchor)
    }

    /// Animates `flightOffset` to `destination` and, once the spring has fully
    /// settled (`.removed` — a `logicallyComplete` snap would clip the spring's
    /// last sub-pixel tail into a visible nudge), snaps the panel to the real
    /// target frame of whatever surface is CURRENT by then.
    private func launchFlightSpring(toward destination: CGSize) {
        flightGeneration += 1
        let generation = flightGeneration
        withAnimation(Theme.Anim.surface, completionCriteria: .removed) {
            flightOffset = destination
        } completion: { [weak self] in
            // SwiftUI animation completions run on the main actor.
            guard let self, self.flightActive, self.flightGeneration == generation else { return }
            self.settleFlight()
        }
    }

    /// The landing: flight state off and the panel snapped to the current
    /// surface's own frame — in one transaction, so pin + zero offset in the
    /// target-sized panel draw the content exactly where the flight left it.
    private func settleFlight() {
        flightActive = false
        flightOffset = .zero
        isAnimatingReframe = false
        guard let panel else { return }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: surface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            chipExtraWidth: chipExtraWidth,
            visible: visible
        )
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
    }

    /// Drops a flight without landing it (snap reframe took over, or the panel
    /// is going away). Offset zeroing is not animated; the caller's own frame
    /// change lands in the same transaction.
    private func cancelFlight() {
        guard flightActive else { return }
        flightGeneration += 1
        flightActive = false
        flightOffset = .zero
        isAnimatingReframe = false
    }

    /// True while an animated reframe is in flight — its intermediate frames also
    /// fire `windowDidMove`, and persisting those would poison the anchors with
    /// mid-animation garbage. `reframe()` already persists the END frame itself.
    private var isAnimatingReframe = false

    /// A user drag moved the panel — update whichever anchor the current surface
    /// owns. Called by the window delegate on `windowDidMove`.
    func panelWasDragged(toLogicalFrame logical: CGRect) {
        guard !isAnimatingReframe else { return }
        // Mid drawer-close (round 5b) the frame is deliberately oversized while
        // the surface is already `.bar` — deriving a bar anchor from it would
        // corrupt the position. The snap lands in a beat and persists the truth.
        guard !pendingDrawerCloseSnap else { return }
        // Round 6 safety net (the camera window's delegate recipe): if a move
        // slipped past the panel's own clamp overrides, push the glass back into
        // the visible frame. The setFrame fires a fresh `windowDidMove`, and THAT
        // pass — now in-bounds — persists the anchor and judges the flip.
        if let panel {
            let visible = currentVisibleFrame(for: panel)
            let clamped = MorphGeometry.clampedIntoVisible(logical, visible: visible)
            if clamped != logical {
                panel.setFrame(MorphGeometry.panelFrame(forLogical: clamped), display: true)
                return
            }
        }
        persistAnchor(forLogicalFrame: logical)
        scheduleDrawerFlipIfNeeded()
        // Dragged over new backdrop — re-judge the Auto look (debounced).
        backdropMonitor.sampleSoon()
    }

    // MARK: Drawer auto-flip on drag (round 6)

    /// Pending re-evaluation of the drawer direction after a drag; nil when the
    /// position agrees with the current direction.
    private var drawerFlipTask: Task<Void, Never>?

    /// How long after the LAST `windowDidMove` the direction is re-judged. Long
    /// enough to never fire between two events of a live drag stream.
    private static let drawerFlipDebounce: TimeInterval = 0.18

    /// Round 6 («якщо шухляда знизу і місце закінчилось — переміщай наверх»):
    /// while a drawer is open, every drag event re-evaluates
    /// `MorphGeometry.drawerOpensUpward` for the bar's new position. A needed
    /// change does NOT flip mid-drag: the up- and down-frames share only the
    /// bar's rows, so reframing while AppKit's drag session is live would yank
    /// the panel out from under the tracked mouse delta. Instead the flip is
    /// debounced past the event stream AND waits for the mouse button to be
    /// released (`pressedMouseButtons` poll) — the drawer changes sides the
    /// moment the user lets go, via the same snap-frame + fade-in language the
    /// drawer open uses (round-5 policy: the bar itself never stirs).
    private func scheduleDrawerFlipIfNeeded() {
        guard case .barWithDrawer = surface, closingDrawerTab == nil, !flightActive,
              let panel else {
            drawerFlipTask?.cancel()
            drawerFlipTask = nil
            return
        }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let desired = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        guard desired != drawerOpensUp else {
            drawerFlipTask?.cancel()
            drawerFlipTask = nil
            return
        }
        drawerFlipTask?.cancel()
        drawerFlipTask = Task { @MainActor [weak self] in
            // Debounce past the drag's event stream, then wait out the button:
            // flipping under a held mouse fights AppKit's drag tracking.
            try? await Task.sleep(nanoseconds: UInt64(Self.drawerFlipDebounce * 1_000_000_000))
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 0x1 != 0 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.performDrawerFlipIfStillNeeded()
        }
    }

    /// The flip itself, re-checked at fire time (the user may have dragged back).
    /// Same mechanism as a drawer open: `drawerOpensUp` swaps inside a
    /// `drawerFade` transaction (the drawer fades in on its new side; the pin
    /// edge follows) and the panel SNAPS to the direction's frame — the bar's
    /// glass does not move a pixel, because both frames are anchored to it.
    private func performDrawerFlipIfStillNeeded() {
        drawerFlipTask = nil
        guard case .barWithDrawer = surface, closingDrawerTab == nil, !flightActive,
              !pendingDrawerCloseSnap, let panel else { return }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let desired = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        guard desired != drawerOpensUp else { return }
        withAnimation(Theme.Anim.drawerFade) { drawerOpensUp = desired }
        reframe(animated: false)
    }

    /// Writes the anchor a logical surface frame implies. A dragged/reframed pill
    /// updates ONLY its own perch (used by this and future takes); every other
    /// surface updates the bar anchor — recovered through `MorphGeometry.barAnchor`
    /// because an upward drawer's frame has the bar at its bottom.
    ///
    /// `intended` (round 9 review) is the anchor the placement was COMPUTED
    /// from, before `targetFrame`'s slide-into-bounds clamp. Programmatic
    /// reframes pass it, and it is what gets saved: a bar near the right edge
    /// that widens by the chip's 71pt slot gets clamped LEFT for display, and
    /// persisting that clamped position used to walk the anchor left for good
    /// — the bar stayed shifted after the chip disappeared. A user DRAG passes
    /// nothing: there the on-screen frame IS the intent.
    private func persistAnchor(forLogicalFrame logical: CGRect, intended: CGPoint? = nil) {
        if surface == .recordingPill {
            Self.savePillAnchor(intended ?? CGPoint(x: logical.minX, y: logical.maxY))
            return
        }
        let anchor = intended ?? MorphGeometry.barAnchor(
            forSurfaceFrame: logical, surface: surface, opensUp: drawerOpensUp
        )
        barAnchor = anchor
        Self.saveAnchor(anchor)
    }

    // MARK: Theme

    /// Watches the desktop under the panel while the Auto theme is on (4.1.0);
    /// its verdicts land in `AppState.autoPanelDark` and come back through
    /// `applyPanelAppearance(smooth: true)`.
    private let backdropMonitor = BackdropLuminanceMonitor()

    /// Pins the panel's NSAppearance to the resolved panel look
    /// (`AppState.panelAppearance`: the explicit Light/Dark choice, or the Auto
    /// verdict). The explicit pin is what makes `Color.adaptive` resolve
    /// per-panel. Called on show(), from CommandBarRootView's
    /// `.onChange(of: appState.appTheme)`, and by the backdrop monitor.
    ///
    /// `smooth` (Auto flips only, verdict 26.08: the alpha dip still read as a
    /// hard blink — «перемикання … ріже око»): NSAppearance is not animatable,
    /// so the flip hides behind a SNAPSHOT CROSSFADE — one bitmap of the old
    /// look pinned over the content, the appearance switched underneath it, the
    /// snapshot dissolved over `themeFadeDuration`. The overlay is click-through
    /// (`hitTest` nil) and hover keeps working: tracking areas belong to the
    /// live views below and never consult z-order.
    func applyPanelAppearance(smooth: Bool = false) {
        guard let appState, let panel else { return }
        let target = appState.panelAppearance
        if smooth, panel.isVisible, panel.appearance?.name != target?.name,
           let contentView = panel.contentView,
           let snapshot = Self.snapshotOverlay(of: contentView) {
            // One fade at a time: a newer flip replaces the previous overlay
            // (with the 6s decision dwell this is belt-and-braces, not a path
            // the monitor can actually race).
            themeFadeOverlay?.removeFromSuperview()
            contentView.addSubview(snapshot)
            themeFadeOverlay = snapshot
            // The live content re-renders in the new look UNDER the snapshot.
            panel.appearance = target
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.themeFadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    snapshot.removeFromSuperview()
                    if let self, self.themeFadeOverlay === snapshot {
                        self.themeFadeOverlay = nil
                    }
                }
            })
        } else {
            panel.appearance = target
        }
        syncBackdropMonitor()
    }

    /// Duration of the Auto-theme crossfade (verdict 26.08).
    private static let themeFadeDuration: TimeInterval = 0.45

    /// The dissolving snapshot of the previous look; nil between crossfades.
    private var themeFadeOverlay: NSImageView?

    /// One bitmap of the content view AS CURRENTLY DRAWN (the old look), wrapped
    /// in a click-through image view covering the whole content view. Sized in
    /// points with the rep carrying the backing scale, so Retina stays sharp.
    ///
    /// ЗАМІР (стенд r10, macOS 26.5.2) — ЩО ЦЕЙ ЗНІМОК НАСПРАВДІ БЕРЕ:
    /// `cacheDisplay` малює офскрін, а Liquid Glass семплить те, що ЗА ВІКНОМ,
    /// тож скляна площина лягає в репу З НУЛЬОВОЮ АЛЬФОЮ. Знімок несе тільки
    /// звичайний вміст — текст, кружки кнопок, мітку запису; сама поверхня
    /// НЕ фейдиться, а перемикається кадром. Доказ у смугах стенда: смуга із
    /// суцільною заливкою (не скло) плавно проявляється всі 0.45с, дві скляні
    /// стрибають в одному кадрі. Тому кросфейд заспокоює ХРОМ, але не тон
    /// панелі; якщо шеф колись поскаржиться, що «тема все одно клацає» —
    /// шукати тут, а не в дебаунсі монітора.
    private static func snapshotOverlay(of contentView: NSView) -> NSImageView? {
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let overlay = ThemeFadeOverlayView(frame: bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        return overlay
    }

    /// The one-line policy behind `syncBackdropMonitor`, pure so the regression
    /// of round 6 stays pinned by a test: the Auto-theme monitor runs exactly
    /// while Auto is chosen AND the panel is actually on screen. The
    /// `panelIsVisible` half is why the ORDER of calls in `show()` matters —
    /// any sync made before `orderFrontRegardless()` must come out as `false`.
    nonisolated static func backdropMonitorShouldRun(
        theme: AppState.AppTheme, panelIsVisible: Bool
    ) -> Bool {
        theme == .auto && panelIsVisible
    }

    /// The monitor runs exactly while: Auto is chosen AND the panel is up
    /// (`backdropMonitorShouldRun`). Everything else puts it to sleep. Silent
    /// without the screen permission — the monitor checks that itself before
    /// every sample.
    private func syncBackdropMonitor() {
        guard let appState, let panel,
              Self.backdropMonitorShouldRun(
                  theme: appState.appTheme, panelIsVisible: panel.isVisible
              ) else {
            backdropMonitor.stop()
            return
        }
        backdropMonitor.onLook = { [weak self] look in
            guard let self, let appState = self.appState else { return }
            appState.autoPanelDark = (look == .dark)
            self.applyPanelAppearance(smooth: true)
        }
        backdropMonitor.start(panel: panel)
    }

    // MARK: Helpers

    private func currentVisibleFrame(for panel: NSPanel? = nil) -> CGRect {
        let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

// MARK: - Theme-fade overlay

/// The crossfade snapshot (verdict 26.08): sits over the live content while the
/// old look dissolves, and never intercepts the mouse — clicks land on the live
/// controls underneath, and their tracking-area hover states keep firing.
private final class ThemeFadeOverlayView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - NSAppearance from app theme

extension NSAppearance {
    /// The ONBOARDING-side mapping (the panels use `AppState.panelAppearance`):
    /// `.auto` maps to nil — inherit — because Auto steers floating panels only,
    /// and the onboarding window follows the system appearance by design (4.1.0).
    static func from(_ theme: AppState.AppTheme) -> NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}
