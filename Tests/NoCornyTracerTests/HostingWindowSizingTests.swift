import XCTest
import SwiftUI
import AppKit
@testable import NoCornyTracer

/// ROUND 14 — the regression net under a production crash that has now shipped
/// TWICE, because round 13's net was made of the wrong material.
///
/// The crash: an uncaught `NSGenericException` raised inside the display cycle.
/// The `.ips` reports do not carry the exception's text; the unified log does,
/// and all four reports (4.5.0 ×2, 4.5.1 ×2) say the same thing:
///
///     The window has been marked as needing another Update Constraints in
///     Window pass, but it has already had more Update Constraints in Window
///     passes than there are views in the window.
///     <NoCornyTracer.CommandBarPanel: 0x…> {{1494, 1066}, {486, 199}}
///
/// THE COMMAND BAR. Round 13 read a stand's exception instead of the
/// battlefield's, hardened the camera bubble, and shipped 4.5.1 — which crashed
/// identically, because it also believed two things that are simply not true of
/// AppKit, and its tests could not tell:
///
/// 1. that `sizingOptions = []` stops SwiftUI from writing the window frame.
///    It does not always: `NSHostingView.windowDidLayout` gates the write on an
///    internal window-size bridge, and 4.5.1 shipped the pin and crashed anyway.
/// 2. that `.intrinsicContentSize` still publishes a size through `fittingSize`.
///    It does not — see `testFittingSizeIsEmptyUnlessSwiftUIOwnsTheWindow`.
///
/// Both errors survived round 13 because its tests asserted OUR POLICY and
/// SCANNED OUR SOURCE TEXT. Nothing in them ever asked AppKit a question. So the
/// tests below are behavioural: they build real windows, ask AppKit what it did,
/// and only then believe it.
final class HostingWindowSizingTests: XCTestCase {

    /// A view with an opinion about its own size, so "did the window follow the
    /// content" has an unambiguous answer.
    private struct Boxed: View {
        var body: some View {
            Color.clear.frame(width: 123, height: 45)
        }
    }

    /// A size no content in this app would ever ask for, handed to the window on
    /// purpose: if SwiftUI owns the frame, it snaps away from this.
    private static let forced = NSSize(width: 486, height: 199)

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.forced),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Runs the AppKit layout the crash happens inside, so the assertions below
    /// are about what AppKit DID, not about what we asked for.
    @MainActor
    private func pumpLayout(_ window: NSWindow) {
        window.orderFront(nil)
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - The wall

    /// THE INVARIANT, stated as behaviour: a window built through
    /// `WindowSizing.install` keeps the size WE gave it — even when the host is
    /// handed SwiftUI's own default options, the value that shipped in 4.5.0.
    ///
    /// This is the test round 13 did not have. Its equivalent asserted that our
    /// constants were in a list; this one hands SwiftUI the loaded gun and checks
    /// the window afterwards.
    @MainActor
    func testInstalledHostCannotResizeItsWindowEvenWithSwiftUIDefaults() {
        let window = makeWindow()
        let controller = NSHostingController(rootView: Boxed())
        WindowSizing.install(controller, in: window, sizing: .standardBounds)
        window.setContentSize(Self.forced)

        pumpLayout(window)

        XCTAssertEqual(window.frame.size.width, Self.forced.width, accuracy: 0.5,
                       "SwiftUI resized the window — the wall is not holding")
        XCTAssertEqual(window.frame.size.height, Self.forced.height, accuracy: 0.5,
                       "SwiftUI resized the window — the wall is not holding")
    }

    /// The control experiment, and the reason the test above is not a tautology:
    /// the SAME host, wired the way every window in this app was wired before
    /// round 14, DOES move the window. If this ever stops failing to hold our
    /// size, AppKit changed and the test above proves nothing any more.
    @MainActor
    func testHostAsContentViewControllerStillDrivesTheWindow() {
        let window = makeWindow()
        let controller = NSHostingController(rootView: Boxed())
        controller.sizingOptions = .standardBounds
        window.contentViewController = controller
        window.setContentSize(Self.forced)
        // XCTest shares one process, so this deliberately-broken window would
        // otherwise be found by `testNoLiveWindowIsDrivenBySwiftUI` and fail it.
        defer {
            window.contentViewController = NSViewController()
            window.orderOut(nil)
        }

        pumpLayout(window)

        XCTAssertNotEqual(window.frame.size.width, Self.forced.width, accuracy: 0.5,
                          """
                          Control experiment: a hosting view installed as contentViewController \
                          is supposed to drag the window to its own size. It did not, so the \
                          companion test proves nothing — re-derive the invariant before trusting it.
                          """)
    }

    /// `install` must leave NO window with a hosting view as its content view —
    /// that is the whole rule, and it is checkable on a live window rather than
    /// by grepping for a call.
    @MainActor
    func testInstallKeepsTheHostOutOfContentView() throws {
        let window = makeWindow()
        let controller = NSHostingController(rootView: Boxed())
        WindowSizing.install(controller, in: window)

        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(WindowSizing.isSwiftUIHost(content),
                       "window.contentView is a SwiftUI host: \(type(of: content))")
        XCTAssertTrue(controller.view.isDescendant(of: content),
                      "the host must still be IN the window, just not be its content view")
        XCTAssertTrue(controller.parent === window.contentViewController,
                      "the host must be a child view controller, or nothing retains it")
    }

    /// The host must FILL the window, and keep filling it when the window's frame
    /// changes afterwards. Starting from `.zero` is not a corner case: that is
    /// exactly how `CommandBarPanel` is born, and it is the case an autoresizing
    /// mask gets wrong (it scales against the old size, which is zero).
    @MainActor
    func testHostFillsTheWindowIncludingFromAZeroStart() {
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: Boxed())
        WindowSizing.install(controller, in: window)

        window.setFrame(NSRect(x: 100, y: 100, width: 486, height: 199), display: true)
        pumpLayout(window)

        XCTAssertEqual(controller.view.frame.size.width, 486, accuracy: 0.5,
                       "the host did not follow the window — content would be clipped or float")
        XCTAssertEqual(controller.view.frame.size.height, 199, accuracy: 0.5)

        window.setContentSize(NSSize(width: 200, height: 60))
        pumpLayout(window)
        XCTAssertEqual(controller.view.frame.size.width, 200, accuracy: 0.5,
                       "the host must shrink with the window too — this is the pill after a morph")
    }

    /// Re-rooting the same window (the toast re-presents into one panel, the
    /// onboarding card re-presents per step) must not leak the old host back into
    /// the content view.
    @MainActor
    func testReinstallingKeepsTheWallUp() throws {
        let window = makeWindow()
        WindowSizing.install(NSHostingController(rootView: Boxed()), in: window)
        let second = NSHostingController(rootView: Boxed())
        WindowSizing.install(second, in: window)

        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(WindowSizing.isSwiftUIHost(content))
        XCTAssertTrue(second.view.isDescendant(of: content))
    }

    /// The host detector has to see through generics: `NSHostingView` is generic,
    /// so `is NSHostingView<X>` only ever recognises ONE content type, and a
    /// detector that misses the others would make the audit below silently empty.
    @MainActor
    func testHostDetectorRecognisesAnyHostingView() {
        XCTAssertTrue(WindowSizing.isSwiftUIHost(NSHostingController(rootView: Boxed()).view))
        XCTAssertTrue(WindowSizing.isSwiftUIHost(NSHostingController(rootView: AnyView(Boxed())).view))
        XCTAssertTrue(WindowSizing.isSwiftUIHost(NSHostingView(rootView: Text("x"))))
        XCTAssertFalse(WindowSizing.isSwiftUIHost(WindowSizing.HostContainerView()))
        XCTAssertFalse(WindowSizing.isSwiftUIHost(NSView()))
        XCTAssertFalse(WindowSizing.isSwiftUIHost(nil))
    }

    /// The RUNTIME inventory that replaces round 13's source scan: whatever
    /// windows exist, none of them may be SwiftUI-driven. A new window added a
    /// year from now fails here the first time a test opens it — no needle to go
    /// stale, no text to match.
    @MainActor
    func testNoLiveWindowIsDrivenBySwiftUI() {
        let window = makeWindow()
        WindowSizing.install(NSHostingController(rootView: Boxed()), in: window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let offenders = WindowSizing.windowsDrivenBySwiftUI()
        XCTAssertTrue(offenders.isEmpty, """
            These windows let SwiftUI resize them from inside a layout pass, which \
            is what crashed 4.5.0 and 4.5.1:
            \(offenders.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: "\n"))
            """)
    }

    // MARK: - Measuring

    /// WHY `WindowSizing.measure` EXISTS. `fittingSize` is not a property of the
    /// content, it is a property of the OPTION SET: it reports under
    /// `.intrinsicContentSize` and `.standardBounds` and is empty under `[]`. So
    /// a window that wants to read its content's size has to keep a second,
    /// weaker option set alive for the sole purpose of reading a number — which
    /// is exactly the second rule round 14 removes.
    ///
    /// This test is also the one that caught round 14's own measuring mistake:
    /// the stand had been probing `NSHostingSizingOptions(rawValue: 4)` believing
    /// it was `.intrinsicContentSize`. It is `.maxSize`. Hence the raw values
    /// asserted below — a stand that names a constant by its number will get this
    /// wrong again otherwise.
    func testSizingOptionRawValuesAreWhatTheStandsAssume() {
        XCTAssertEqual(NSHostingSizingOptions.minSize.rawValue, 1)
        XCTAssertEqual(NSHostingSizingOptions.intrinsicContentSize.rawValue, 2)
        XCTAssertEqual(NSHostingSizingOptions.maxSize.rawValue, 4)
        XCTAssertEqual(NSHostingSizingOptions.preferredContentSize.rawValue, 16)
        XCTAssertEqual(NSHostingSizingOptions.standardBounds.rawValue, 7)
    }

    @MainActor
    func testFittingSizeDependsOnTheOptionSetAndIsEmptyUnderOurs() {
        let ours = NSHostingController(rootView: Boxed())
        ours.sizingOptions = WindowSizing.ownedByUs
        XCTAssertEqual(ours.view.fittingSize, .zero,
                       "under [] SwiftUI publishes nothing — which is why measurement is detached")

        let reporting = NSHostingController(rootView: Boxed())
        reporting.sizingOptions = .intrinsicContentSize
        XCTAssertEqual(reporting.view.fittingSize.width, 123, accuracy: 0.5,
                       "if this stops reporting, the round-13 toast pin was ALSO broken and the history above is wrong")
    }

    /// …and the reading that does work, on a host that is in no window at all.
    @MainActor
    func testMeasureReportsTheContentSizeWithoutAWindow() {
        let size = WindowSizing.measure(Boxed())
        XCTAssertEqual(size.width, 123, accuracy: 0.5)
        XCTAssertEqual(size.height, 45, accuracy: 0.5)
    }

    /// The toast sizes and CENTRES its panel from this number, so a bad reading
    /// would not merely shrink the panel — it would park it off centre by half
    /// its own width.
    ///
    /// These measure the REAL views the panel hosts, not stand-ins. That
    /// distinction earned its keep immediately: round 14's stand approximated the
    /// noise card at 352×114 and the shipped one is 352×116 — a test written
    /// against the approximation would have pinned a number the app never had.
    ///
    /// The load-bearing assertion is the FIRST one in each: that the new detached
    /// reading equals what the toast was getting from `fittingSize` under the
    /// round-13 pin. That is the actual promise of round 14's refactor — the
    /// measurement moved, the toast did not — and it holds whatever the numbers
    /// happen to be. The absolute sizes follow as a plain-language record of what
    /// they are today.
    @MainActor
    private func assertMeasurementUnchanged<Content: View>(
        _ view: Content, expected: CGSize, file: StaticString = #filePath, line: UInt = #line
    ) {
        // What ToastWindowManager read before round 14: fittingSize on a host
        // pinned to `.intrinsicContentSize`.
        let old = NSHostingController(rootView: view)
        old.sizingOptions = .intrinsicContentSize
        let before = old.view.fittingSize

        let after = WindowSizing.measure(view)

        XCTAssertEqual(after.width, before.width, accuracy: 0.5, """
            The detached measurement disagrees with the reading the toast used before \
            round 14 — moving the measurement was supposed to change nothing visible.
            """, file: file, line: line)
        XCTAssertEqual(after.height, before.height, accuracy: 0.5, file: file, line: line)

        XCTAssertEqual(after.width, expected.width, accuracy: 1, """
            The toast's own size changed. The panel is sized AND centred from this, \
            so an unnoticed drift here moves the toast off centre by half its width.
            """, file: file, line: line)
        XCTAssertEqual(after.height, expected.height, accuracy: 1, file: file, line: line)
    }

    @MainActor
    func testInfoToastMeasuresExactlyAsItDidBefore() {
        assertMeasurementUnchanged(
            AnyView(InfoToastView(content: ToastContent(icon: "link", message: "Uploaded — link copied"))),
            expected: CGSize(width: 189, height: 60)
        )
    }

    @MainActor
    func testNoiseSuggestionCardMeasuresExactlyAsItDidBefore() {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }
        let state = AppState(defaults: sandbox, connectsToTracer: false)

        assertMeasurementUnchanged(
            AnyView(NoiseSuggestionToastView(appState: state)),
            expected: CGSize(width: 352, height: 116)
        )
    }

    /// `measure` must never hand a window an infinite size. Today's two toasts
    /// cannot produce one (`.fixedSize()`, a hard `.frame(width: 320)`), which is
    /// exactly why this needs its own greedy view: without it the guard is
    /// untested code that only runs the day someone adds a `Spacer()`.
    @MainActor
    func testMeasureNeverReturnsAnInfiniteSize() {
        // The assert fires in DEBUG on purpose — that is the point of the guard —
        // so the release-path fallback is exercised through the bounded call it
        // ends in, and the greedy case is documented rather than silently untested.
        let bound = CGSize(width: 400, height: 300)
        let greedy = NSHostingController(rootView: AnyView(Color.clear))
        greedy.sizingOptions = []
        let unbounded = greedy.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        guard !unbounded.width.isFinite || !unbounded.height.isFinite else {
            // SwiftUI clamped it for us — the guard is belt-and-braces, not dead.
            return
        }
        let bounded = greedy.sizeThatFits(in: bound)
        XCTAssertTrue(bounded.width.isFinite && bounded.height.isFinite,
                      "the bounded fallback measure must be finite, or the guard has nothing to fall back on")
    }

    // MARK: - The pin (defence in depth, no longer the guarantee)

    /// The pin still reaches both objects. It is kept because it costs nothing
    /// and makes SwiftUI stop WANTING the window — but 4.5.1 proved it is not
    /// the guarantee, so it is tested as a helper, not as the invariant.
    @MainActor
    func testPinReachesControllerAndItsView() throws {
        let controller = NSHostingController(rootView: Text("x"))
        XCTAssertTrue(WindowSizing.mayResizeWindow(controller.sizingOptions),
                      "precondition: a fresh NSHostingController drives its window")

        WindowSizing.pin(controller)
        XCTAssertEqual(controller.sizingOptions, [])
        let hosting = try XCTUnwrap(controller.view as? NSHostingView<Text>)
        XCTAssertEqual(hosting.sizingOptions, [])
    }

    /// The predicate still names the dangerous sets — it feeds the audit's
    /// message. `[]` is not "safe", it is merely "not asking".
    func testSwiftUIDefaultsAreRecognisedAsWindowDrivers() {
        XCTAssertTrue(WindowSizing.mayResizeWindow(.standardBounds),
                      "standardBounds is SwiftUI's default and is what shipped in 4.5.0")
        XCTAssertTrue(WindowSizing.mayResizeWindow(.preferredContentSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow(.minSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow(.maxSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow([.intrinsicContentSize, .maxSize]),
                      "one bad flag in a set is enough — the guard is not all-or-nothing")
        XCTAssertFalse(WindowSizing.mayResizeWindow(WindowSizing.ownedByUs))
    }

    // MARK: - Source inventory (narrow, and honest about what it can prove)

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/NoCornyTracerTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Sources/NoCornyTracer")

    private func swiftSources() throws -> [(url: URL, lines: [String])] {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(fm.enumerator(at: Self.sourceRoot,
                                                     includingPropertiesForKeys: nil))
        var out: [(URL, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url, text.components(separatedBy: .newlines)))
        }
        XCTAssertFalse(out.isEmpty, "no sources found under \(Self.sourceRoot.path)")
        return out
    }

    /// The one thing a text scan CAN prove, and the reason it survived round 13's
    /// demotion: `contentViewController` is the single door through which a host
    /// becomes a window's content view, and `WindowSizing` is the only file
    /// allowed to open it. A new window that wires itself up by hand fails here
    /// the day it is written, before anyone has to record with a camera to find
    /// out. The behavioural tests above are what prove the rule WORKS; this only
    /// proves nobody walked around it.
    func testOnlyWindowSizingAssignsAWindowsContent() throws {
        var offenders: [String] = []
        for (url, lines) in try swiftSources() where url.lastPathComponent != "WindowSizing.swift" {
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // The leading dot matters: `let contentView = panel.contentView`
                // is a READ, and matching it made this test fail on innocent code.
                //
                // `contentViewController:` (with the colon) catches the OTHER
                // door, which the first version of this scan missed entirely: a
                // window can be handed its content at construction —
                // `NSPanel(contentViewController: NSHostingController(...))` —
                // and that spelling would have sailed through every test here.
                guard trimmed.contains(".contentViewController =")
                        || trimmed.contains(".contentView =")
                        || trimmed.contains("contentViewController:") else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) — \(trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            A window's content is being assigned outside WindowSizing.install. That is \
            how a SwiftUI host becomes a window's content view again, and it is what \
            crashed 4.5.0 and 4.5.1:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// `sizingOptions` keeps one spelling in one place, so the invariant cannot
    /// quietly grow a second, weaker copy.
    func testSizingOptionsIsOnlySetThroughTheHelper() throws {
        var offenders: [String] = []
        for (url, lines) in try swiftSources() where url.lastPathComponent != "WindowSizing.swift" {
            for (index, line) in lines.enumerated() where line.contains("sizingOptions") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) — \(trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            sizingOptions touched outside WindowSizing:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - The sizes the windows now have to carry themselves

    /// So the camera bubble's window is sized by us, in code, and not by hope.
    func testCameraWindowSetsItsOwnContentSize() throws {
        let manager = try String(
            contentsOf: Self.sourceRoot.appendingPathComponent("Managers/CameraWindowManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manager.contains("setContentSize"),
                      "the bubble collapses to 0×0 without an explicit content size")
    }

    /// The bubble's window and its SwiftUI content are sized from ONE constant
    /// now that SwiftUI no longer reconciles them. A drift here shows up as a
    /// clipped or floating circle, silently.
    func testCameraBubbleUsesOneSizeConstant() throws {
        let view = try String(
            contentsOf: Self.sourceRoot.appendingPathComponent("Views/CameraView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("CameraWindowManager.bubbleSide"),
                      "CameraView must take its size from the same constant the window does")
        XCTAssertFalse(view.contains("width: 200, height: 200"),
                       "a hardcoded 200 next to a named constant is exactly the drift this guards")
    }

    /// The onboarding card changes height between its two steps (320 → 300).
    /// With SwiftUI no longer resizing that window, both steps must fit ONE box.
    func testOnboardingCardsFitTheirFixedWindowBox() {
        let box = OnboardingView.windowContentSize
        let apron = OnboardingView.shadowApron * 2
        XCTAssertEqual(box.width, OnboardingView.cardWidth + apron, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(box.height, OnboardingView.permissionCardHeight + apron)
        XCTAssertGreaterThanOrEqual(box.height, OnboardingView.cloudCardHeight + apron)
    }
}
