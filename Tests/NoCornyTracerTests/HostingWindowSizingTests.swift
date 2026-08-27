import XCTest
import SwiftUI
import AppKit
@testable import NoCornyTracer

/// ROUND 13 — the regression net under the 4.5.0 production crash («застосунок
/// вилітає, якщо увімкнути запис З КАМЕРОЮ», two reports on 27.08).
///
/// The crash was an uncaught `NSGenericException` raised inside the display
/// cycle, verbatim:
///
///     The window has been marked as needing another Update Constraints in
///     Window pass, but it has already had more Update Constraints in Window
///     passes than there are views in the window.
///
/// Cause: the camera bubble's `NSHostingController` was created with SwiftUI's
/// DEFAULT `sizingOptions`, so SwiftUI drove the window's frame from inside the
/// layout pass; each write re-dirtied the window's constraints and asked for
/// another update-constraints pass, and the bubble is a three-view window, so
/// AppKit's runaway guard tripped almost immediately.
///
/// The class is invisible in review — a `NSHostingController(rootView:)` that
/// forgets one line looks exactly like one that does not — so it is pinned by a
/// SOURCE INVENTORY rather than by a promise. Two halves:
/// 1. the policy itself (`WindowSizing.mayResizeWindow`), pure and testable;
/// 2. every hosting site in the app, read out of the source.
final class HostingWindowSizingTests: XCTestCase {

    // MARK: - The policy

    /// The two option sets this app is allowed to hand SwiftUI. Neither may
    /// resize a window — that is the whole invariant.
    func testAllowedOptionsNeverResizeTheWindow() {
        XCTAssertFalse(WindowSizing.mayResizeWindow(WindowSizing.ownedByUs))
        XCTAssertFalse(WindowSizing.mayResizeWindow(WindowSizing.measuredByUsOnly))
        XCTAssertTrue(WindowSizing.ownedByUs.isEmpty)
        XCTAssertEqual(WindowSizing.measuredByUsOnly, .intrinsicContentSize)
    }

    /// The values that DID crash 4.5.0, so the predicate is a real test and not
    /// a tautology over two constants we happen to have chosen.
    func testSwiftUIDefaultsAreRecognisedAsWindowDrivers() {
        XCTAssertTrue(WindowSizing.mayResizeWindow(.standardBounds),
                      "standardBounds is SwiftUI's default and is what shipped in 4.5.0")
        XCTAssertTrue(WindowSizing.mayResizeWindow(.preferredContentSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow(.minSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow(.maxSize))
        XCTAssertTrue(WindowSizing.mayResizeWindow([.intrinsicContentSize, .maxSize]),
                      "one bad flag in a set is enough — the guard is not all-or-nothing")
    }

    // MARK: - The pin actually reaches the view

    /// `NSHostingController.sizingOptions` and `NSHostingView.sizingOptions` are
    /// two different objects' properties, and AppKit asks the VIEW. Setting only
    /// the controller is the shape of the bug that ships.
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

    /// The measuring variant still lets us READ a size (the toast and the
    /// onboarding card both size their window from `fittingSize`) while keeping
    /// SwiftUI's hands off the window.
    /// `AnyView`, because that is exactly how the toast is rooted — a measuring
    /// pin that returned zero there would ship an invisible toast, which is a
    /// worse bug than the crash it replaces.
    @MainActor
    func testMeasuringPinKeepsFittingSizeButNotTheWindow() {
        let controller = NSHostingController(
            rootView: AnyView(Color.clear.frame(width: 123, height: 45))
        )
        WindowSizing.pin(controller, to: WindowSizing.measuredByUsOnly)
        XCTAssertFalse(WindowSizing.mayResizeWindow(controller.sizingOptions))
        XCTAssertEqual(controller.view.fittingSize.width, 123, accuracy: 0.5)
        XCTAssertEqual(controller.view.fittingSize.height, 45, accuracy: 0.5)
    }

    /// The mirror image: the OWNING pin reports nothing, so any window using it
    /// has to carry its own size. Forgetting that is how the camera bubble ends
    /// up 0×0 (stand run E) — the window shrinks to zero when the content view
    /// controller is attached and nobody puts it back any more.
    @MainActor
    func testOwningPinReportsNoSizeAtAll() {
        let controller = NSHostingController(
            rootView: AnyView(Color.clear.frame(width: 123, height: 45))
        )
        WindowSizing.pin(controller)
        XCTAssertEqual(controller.view.fittingSize, .zero,
                       "with sizingOptions = [] SwiftUI reports nothing — the window must size itself")
    }

    /// So the camera bubble's window is sized by us, in code, and not by hope.
    func testCameraWindowSetsItsOwnContentSize() throws {
        let manager = try String(
            contentsOf: Self.sourceRoot.appendingPathComponent("Managers/CameraWindowManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manager.contains("setContentSize"),
                      "the bubble collapses to 0×0 without an explicit content size (stand run E)")
    }

    // MARK: - Source inventory

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

    /// EVERY place the app builds a SwiftUI host must hand the size back to us,
    /// through `WindowSizing` and nowhere else. A new window added a year from
    /// now fails here on the day it is written, not on the day a user records
    /// with the camera on.
    func testEveryHostingSiteHandsTheSizeBackToUs() throws {
        // How far after the construction the pin may live: enough for the
        // `let x = NSHostingController(...)` / comment / pin idiom, tight enough
        // that "somewhere later in the file" does not count.
        let reach = 12
        var offenders: [String] = []

        for (url, lines) in try swiftSources() {
            // The helper itself is where the pinning is implemented.
            if url.lastPathComponent == "WindowSizing.swift" { continue }

            for (index, line) in lines.enumerated() {
                let isConstruction = line.contains("NSHostingController(")
                    || line.contains("NSHostingView(")
                    || line.contains("CommandBarHostingView(")
                    || line.contains("CommandBarHostingController(")
                guard isConstruction, !line.hasPrefix("//"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }

                let window = lines[index..<min(index + reach, lines.count)].joined(separator: "\n")
                guard !window.contains("WindowSizing.pin") else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            SwiftUI host built without WindowSizing.pin — it will drive its window \
            from inside the layout pass and can crash the app the way 4.5.0 did:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Nobody may set `sizingOptions` by hand any more: one spelling, one place,
    /// one story. (A raw `sizingOptions =` outside `WindowSizing` is how the
    /// invariant quietly grows a second, weaker copy.)
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

    // MARK: - The camera bubble's fixed size

    /// The bubble's window and its SwiftUI content are sized from ONE constant
    /// now that SwiftUI no longer reconciles them (round 13). A drift here shows
    /// up as a clipped or floating circle, silently.
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
