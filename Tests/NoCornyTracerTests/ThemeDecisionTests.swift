import XCTest
import AppKit
@testable import NoCornyTracer

/// The Auto theme's pure pieces (4.1.0): the hysteresis that decides the panel
/// look from the backdrop luminance, the luminance math itself, and the
/// persistence rule that keeps existing users on their explicit choice.
final class ThemeDecisionTests: XCTestCase {

    // MARK: - Hysteresis

    func testBrightBackdropDemandsTheLightLook() {
        XCTAssertEqual(ThemeDecision.next(current: .dark, luminance: 0.63), .light)
        XCTAssertEqual(ThemeDecision.next(current: .light, luminance: 0.95), .light)
    }

    func testDarkBackdropDemandsTheDarkLook() {
        XCTAssertEqual(ThemeDecision.next(current: .light, luminance: 0.44), .dark)
        XCTAssertEqual(ThemeDecision.next(current: .dark, luminance: 0.05), .dark)
    }

    /// The band between the thresholds holds whatever is shown — a backdrop
    /// hovering around one threshold can never strobe the bar between themes.
    func testTheBandBetweenThresholdsHoldsTheCurrentLook() {
        for luminance in [0.46, 0.50, 0.55, 0.61] {
            XCTAssertEqual(ThemeDecision.next(current: .dark, luminance: luminance), .dark)
            XCTAssertEqual(ThemeDecision.next(current: .light, luminance: luminance), .light)
        }
    }

    /// Exactly ON a threshold is still inside the holding band (strict compares).
    func testExactThresholdsStillHold() {
        XCTAssertEqual(ThemeDecision.next(current: .dark, luminance: ThemeDecision.lightThreshold), .dark)
        XCTAssertEqual(ThemeDecision.next(current: .light, luminance: ThemeDecision.darkThreshold), .light)
    }

    // MARK: - Luminance math

    /// White averages to ~1, black to ~0 — the Rec.709 weighting is sane.
    func testAverageLuminanceOnSolidImages() throws {
        func solid(_ color: CGColor) throws -> CGImage {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 8 * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try XCTUnwrap(context.makeImage())
        }
        let white = BackdropLuminanceMonitor.averageLuminance(of: try solid(.white))
        let black = BackdropLuminanceMonitor.averageLuminance(of: try solid(.black))
        XCTAssertEqual(white, 1.0, accuracy: 0.02)
        XCTAssertEqual(black, 0.0, accuracy: 0.02)
        // And the two land on the two sides of both thresholds.
        XCTAssertEqual(ThemeDecision.next(current: .dark, luminance: white), .light)
        XCTAssertEqual(ThemeDecision.next(current: .light, luminance: black), .dark)
    }

    // MARK: - Theme persistence / migration

    /// A fresh install (no saved key) lands on Auto; an existing explicit choice
    /// keeps being respected — Auto never overrides a saved Light/Dark.
    @MainActor
    func testThemeDefaultsToAutoOnlyWithoutASavedChoice() {
        func appState(seedTheme: String?) -> AppState {
            let suite = UserDefaults(suiteName: "theme-migration-tests")!
            suite.removePersistentDomain(forName: "theme-migration-tests")
            if let seedTheme { suite.set(seedTheme, forKey: "appTheme") }
            return AppState(defaults: suite, connectsToTracer: false)
        }
        XCTAssertEqual(appState(seedTheme: nil).appTheme, .auto, "new users start on Auto")
        XCTAssertEqual(appState(seedTheme: "light").appTheme, .light, "a saved choice is respected")
        XCTAssertEqual(appState(seedTheme: "dark").appTheme, .dark)
        XCTAssertEqual(appState(seedTheme: "auto").appTheme, .auto, "and Auto round-trips by rawValue")
    }

    /// The panel-appearance resolution: explicit themes pin, Auto follows the
    /// monitor's verdict, and without a verdict panels inherit the system look.
    @MainActor
    func testPanelAppearanceResolution() {
        let suite = UserDefaults(suiteName: "theme-resolution-tests")!
        suite.removePersistentDomain(forName: "theme-resolution-tests")
        let appState = AppState(defaults: suite, connectsToTracer: false)

        appState.appTheme = .dark
        XCTAssertEqual(appState.panelAppearance?.name, .darkAqua)
        appState.appTheme = .light
        XCTAssertEqual(appState.panelAppearance?.name, .aqua)

        appState.appTheme = .auto
        appState.autoPanelDark = nil
        XCTAssertNil(appState.panelAppearance, "no verdict → follow the system")
        appState.autoPanelDark = true
        XCTAssertEqual(appState.panelAppearance?.name, .darkAqua)
        appState.autoPanelDark = false
        XCTAssertEqual(appState.panelAppearance?.name, .aqua)

        // The onboarding-side mapping ignores the verdict on purpose.
        XCTAssertNil(NSAppearance.from(.auto), "onboarding follows the system under Auto")
    }
}
