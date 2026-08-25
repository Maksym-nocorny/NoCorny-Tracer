import SwiftUI
import CoreText

// MARK: - Theme

/// Centralized design system tokens aligned with the NoCorny Agency Design System.
enum Theme {

    // MARK: - Colors

    enum Colors {
        // Brand
        static let brandPurple = Color.adaptive(
            light: Color(hex: 0x3E0693),
            dark: Color(hex: 0xC084FC)
        )
        static let lightPurple = Color.adaptive(
            light: Color(hex: 0x6B00DE),
            dark: Color(hex: 0xD8B4FE)
        )
        static let pink = Color(hex: 0xFF08DE)
        static let orange = Color(hex: 0xFF6900)
        static let yellow = Color(hex: 0xFFC72C)
        static let red = Color(hex: 0xF9423A)
        static let green = Color(hex: 0x00C040)

        // Backgrounds (Design System semantic) — adaptive for dark mode
        static let backgroundPrimary = Color.adaptive(
            light: .white,
            dark: Color(hex: 0x1C1C1E)
        )
        static let backgroundSecondary = Color.adaptive(
            light: Color(hex: 0xEEEEEE),
            dark: Color(hex: 0x2C2C2E)
        )
        static let cardBackground = Color.adaptive(
            light: Color(hex: 0xF5F3F7),
            dark: Color(hex: 0x2A2830)
        )

        // Neutrals — adaptive
        static let neutralBackground = Color.adaptive(
            light: Color(hex: 0xF5F3F7),
            dark: Color(hex: 0x2A2830)
        )
        static let textPrimary = Color.adaptive(
            light: Color(hex: 0x212121),
            dark: Color(hex: 0xF0F0F0)
        )
        static let textAlternate = Color.white

        // Tab bar
        static let tabActiveBackground = Color.adaptive(
            light: .white,
            dark: Color(hex: 0x3A3A3C)
        )

        // MARK: Redesign (command bar) accents
        // Dark values measured on Figma node 76:168 / icon-v2 family,
        // light values measured on Figma node 229:838 (light bar macro).

        /// Recording accent — orange-red of the icon-v2 family (#F2584F → #CE3B33).
        static let recordRed = Color.adaptive(
            light: Color(hex: 0xCE3B33),
            dark: Color(hex: 0xF2584F)
        )
        /// Macro green (#32D74B): toggles, quota bar, "Ready" dots, uploaded checks —
        /// surfaces the macro itself paints in this exact value.
        static let statusGreen = Color(hex: 0x32D74B)
        /// The mic/cam status dots on the BAR specifically (verdict 25.08: "салатові
        /// кислотні"). The bar floats over the wallpaper all day, and the raw macro
        /// green at 8pt read as acid there — one notch deeper, no glow, drawn at 6pt.
        /// Drawer/toast greens stay on `statusGreen`, which the macro shows verbatim.
        static let statusGreenDot = Color.adaptive(
            light: Color(hex: 0x1F9C3D),
            dark: Color(hex: 0x2DB84C)
        )
        /// Pause ring / storage banner amber. Dark measured (#F0B24A);
        /// light is a same-hue darkened derivative — verify against light frames in phase 2.
        static let pausedAmber = Color.adaptive(
            light: Color(hex: 0xC98B2D),
            dark: Color(hex: 0xF0B24A)
        )

        // MARK: Glass surface tokens
        // Light ink base is #0B1220 (dark navy), straight from the light bar macro.

        /// Border of primary controls on glass (capture-mode toggle).
        static let glassStroke = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.13),
            dark: Color(hex: 0xFFFFFF, opacity: 0.16)
        )
        /// Border of secondary controls on glass (library / settings).
        static let glassStrokeSubtle = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.06),
            dark: Color(hex: 0xFFFFFF, opacity: 0.08)
        )
        /// Fill of primary controls on glass (capture-mode toggle).
        static let glassControlFill = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.05),
            dark: Color(hex: 0xFFFFFF, opacity: 0.10)
        )
        /// Fill of secondary controls on glass (library / settings).
        static let glassControlFillSubtle = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.02),
            dark: Color(hex: 0xFFFFFF, opacity: 0.04)
        )
        /// Hover fill of primary controls — one step brighter than `glassControlFill`.
        /// (Secondary controls hover to `glassControlFill`, the next step up for them.)
        static let glassControlFillHover = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.09),
            dark: Color(hex: 0xFFFFFF, opacity: 0.15)
        )
        /// Deep navy-black wash painted OVER the fallback blur (macOS < 26). This is
        /// what kills the grey cast the old `.hudWindow` material gave the surfaces
        /// (verdict 24.08: "скло сіре") — the reference glass is dark and deep, not
        /// grey. Dark raised 0.52 → 0.70 in round 5 (бойова 4.0.0, «на білому фоні
        /// дарк тема стає майже невидимою»): the same luminance-floor policy as the
        /// 26+ glass — over a white window the blur lightens, and the wash must be
        /// strong enough to keep white text readable regardless of the backdrop.
        static let glassBackdropTint = Color.adaptive(
            light: Color(hex: 0xFFFFFF, opacity: 0.22),
            dark: Color(hex: 0x05080F, opacity: 0.70)
        )
        /// Tint handed to native Liquid Glass (macOS 26+). DARK IS DELIBERATELY DEEP:
        /// a 62% navy over the `.regular` frost — the frost supplies the luminance
        /// floor, the saturated tint supplies the tone. History of the pendulum:
        /// 30% over `.regular` was a grey plate (verdict 25.08 «скло досі сіре» —
        /// the WEAK TINT was the culprit); the round-2 fix swung to `.clear`+62%,
        /// which read beautifully over dark wallpapers but handed 38% of the
        /// surface to the backdrop — over a white window the dark bar washed out to
        /// unreadable (вердикт з бойової 4.0.0). `.regular`+62% is the pairing that
        /// holds both: deep navy tone AND a guaranteed floor on any backdrop.
        /// (SDK checked, not guessed: `Glass` exposes only regular/clear/identity +
        /// tint/interactive, and NSGlassEffectView only style+tintColor — there is
        /// no luminosity knob, so variant+tint IS the whole instrument.)
        static let liquidGlassTint = Color.adaptive(
            light: Color(hex: 0xFFFFFF, opacity: 0.10),
            dark: Color(hex: 0x0B1220, opacity: 0.62)
        )
        /// 1pt divider inside the command bar.
        static let glassDivider = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.05),
            dark: Color(hex: 0xFFFFFF, opacity: 0.10)
        )
        /// Idle 00:00 timer color.
        static let timerDimmed = Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: 0.37),
            dark: Color(hex: 0xFFFFFF, opacity: 0.40)
        )

        // Gradients
        static let primaryGradient = LinearGradient(
            colors: [
                Color.adaptive(light: Color(hex: 0x3E0693), dark: Color(hex: 0xA855F7)),
                Color.adaptive(light: Color(hex: 0x6B00DE), dark: Color(hex: 0xC084FC))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        static let dangerGradient = LinearGradient(
            colors: [Color(hex: 0xD92D20), red],
            startPoint: .leading,
            endPoint: .trailing
        )
        static let neutralGradient = LinearGradient(
            colors: [Color(hex: 0x555555), Color(hex: 0x777777)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Typography

    enum Typography {
        private static var _fontsRegistered = false

        static func registerFonts() {
            guard !_fontsRegistered else { return }
            _fontsRegistered = true

            // Mulish is a variable font (single file), PT Sans has regular + bold,
            // JetBrains Mono (regular + medium) drives the redesign timer.
            let fontFiles = ["Mulish", "PTSans-Regular", "PTSans-Bold", "JetBrainsMono-Regular", "JetBrainsMono-Medium"]

            // Try multiple bundle/path combinations to find fonts
            let bundles: [(String, Bundle)] = [
                ("appResources", Bundle.appResources),
                ("main", Bundle.main)
            ]
            let subdirs: [String?] = ["Resources/Fonts", "Fonts", nil]

            for name in fontFiles {
                var found = false
                for (bundleName, bundle) in bundles {
                    for subdir in subdirs {
                        if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: subdir) {
                            var errorRef: Unmanaged<CFError>?
                            let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
                            if success {
                                LogManager.shared.log("✅ Font registered: \(name) from \(bundleName)/\(subdir ?? "root")")
                            } else {
                                let error = errorRef?.takeRetainedValue()
                                LogManager.shared.log("⚠️ Font register failed: \(name) — \(error?.localizedDescription ?? "unknown")")
                            }
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
                if !found {
                    LogManager.shared.log("❌ Font file not found: \(name).ttf in any bundle/subdir")
                }
            }

            // Log availability check
            LogManager.shared.log("Font check — Mulish available: \(hasMulish), PT Sans available: \(hasPTSans), JetBrains Mono available: \(hasJetBrainsMono)")
        }

        /// Whether the custom Mulish font is available.
        private static var hasMulish: Bool {
            NSFont(name: "Mulish-ExtraLight", size: 12) != nil
        }

        /// Whether the custom PT Sans font is available.
        private static var hasPTSans: Bool {
            NSFont(name: "PTSans-Regular", size: 12) != nil
        }

        /// Whether the bundled JetBrains Mono font is available.
        private static var hasJetBrainsMono: Bool {
            NSFont(name: "JetBrainsMono-Medium", size: 12) != nil
        }

        /// Global size bump applied to all typography (makes text larger throughout the app).
        private static let sizeOffset: CGFloat = 1

        /// Heading font (PT Sans, fallback: system).
        static func heading(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            let s = size + sizeOffset
            if hasPTSans {
                let name = weight == .bold ? "PTSans-Bold" : "PTSans-Regular"
                return .custom(name, size: s)
            }
            return .system(size: s, weight: weight)
        }

        /// Body font (Mulish variable font, fallback: system).
        /// Default weight is .medium for better readability at small sizes.
        static func body(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            let s = size + sizeOffset
            if hasMulish {
                return .custom("Mulish", size: s).weight(weight)
            }
            return .system(size: s, weight: weight)
        }

        /// Monospaced font (always system).
        static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size + sizeOffset, weight: weight, design: .monospaced)
        }

        /// Timer font of the redesign (JetBrains Mono Medium, fallback: system monospaced).
        /// No sizeOffset — the command-bar timer is sized exactly per the redesign specs.
        static func timer(_ size: CGFloat) -> Font {
            if hasJetBrainsMono {
                return .custom("JetBrainsMono-Medium", size: size)
            }
            return .system(size: size, weight: .medium, design: .monospaced)
        }
    }

    // MARK: - Metrics (redesign fixed sizes)

    enum Metrics {
        static let commandBarSize = CGSize(width: 560, height: 80)
        static let drawerSize = CGSize(width: 560, height: 332)
        /// The pill's BASE size — the designer's canon (round 3 mockup): 341×54 =
        /// 10 + stop 38 + timer 57 + pause 28 + discard 28 + divider 1 + mic 30 +
        /// cam 30 + divider 1 + hide 28 + 10, gaps of 10. Transient content the
        /// mockup doesn't draw (a 100+ minute timer outgrowing its 57-pt slot)
        /// grows the panel DYNAMICALLY past this base — see CommandBarWindowManager's
        /// `setRecordingPillContentWidth`; anchors and the perch flight are always
        /// computed from the base.
        static let recordingPillSize = CGSize(width: 341, height: 54)
        static let cameraBubble: CGFloat = 180
        static let barCornerRadius: CGFloat = 34
        static let controlSize: CGFloat = 38
        static let controlCornerRadius: CGFloat = 19
    }

    // MARK: - Glass

    enum Glass {
        /// AppKit blur behind floating panels — the FALLBACK glass for macOS < 26
        /// (macOS 26+ surfaces use the native Liquid Glass `glassEffect`, see
        /// `View.glassSurface`). `.popover` is a cleaner blur than the retired
        /// `.hudWindow`, whose grey wash is what the 24.08 verdict called out;
        /// `glassBackdropTint` on top of it gives the deep dark of the reference.
        struct GlassBackground: NSViewRepresentable {
            var material: NSVisualEffectView.Material = .popover

            func makeNSView(context: Context) -> NSVisualEffectView {
                let view = NSVisualEffectView()
                view.material = material
                view.blendingMode = .behindWindow
                view.state = .active
                return view
            }

            func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
                nsView.material = material
            }
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
        static let section: CGFloat = 32
    }

    // MARK: - Border Radius

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let pill: CGFloat = 9999
    }

    // MARK: - Shadows

    enum Shadows {
        static func card(_ content: some View) -> some View {
            content.shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
        }

        static func cardHover(_ content: some View) -> some View {
            content.shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        }

        /// Floating glass panel shadow from the redesign macro: 0px 22px 27.5px rgba(0,0,0,0.55).
        static func floatingPanel(_ content: some View) -> some View {
            content.shadow(color: .black.opacity(0.55), radius: 27.5, x: 0, y: 22)
        }
    }

    // MARK: - Animation

    enum Anim {
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let smooth: SwiftUI.Animation = .easeInOut(duration: 0.5)
        /// Pill-morph companion: the bar↔pill crossfade tuned to ride alongside
        /// the panel's 0.28s frame animation. Since round 5 this drives ONLY the
        /// pill transitions — drawer morphs are frame-snap + `drawerFade`.
        static let surface: SwiftUI.Animation = .spring(response: 0.32, dampingFraction: 0.85)
        /// The only motion a drawer/banner morph carries (round 5, «хай плашка
        /// буде спокійною»): a short fade on the drawer content itself, while the
        /// bar and the panel frame stay inert.
        static let drawerFade: SwiftUI.Animation = .easeOut(duration: 0.15)
        /// Toast / background-pill entrances (slide-in from the top + fade).
        static let toast: SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.8)
        /// Button hover feedback (fill step + scale).
        static let hover: SwiftUI.Animation = .easeOut(duration: 0.15)
    }
}

// MARK: - Card ViewModifier

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.xl)
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.08),
                radius: 8, x: 0, y: 2
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }

    /// Rounded "liquid glass" surface.
    ///
    /// macOS 26+: REAL Liquid Glass via SwiftUI's `glassEffect(_:in:)` (the SwiftUI
    /// face of AppKit's `NSGlassEffectView`, both macOS 26.0+ in the SDK). BOTH
    /// schemes ride the `.regular` variant since round 5 (бойова 4.0.0: dark on a
    /// white background washed out to unreadable): `.regular`'s adaptive frost is
    /// the luminance floor that keeps the surface separated from ANY backdrop —
    /// which is the material's whole job — while the saturated 62% navy
    /// `liquidGlassTint` keeps the deep dark tone the sec1-bar reference shows
    /// (the round-2 «сіре скло» came from a weak 30% tint, not from `.regular`).
    /// Dark also carries the hairline `glassStroke`: over a bright backdrop the
    /// material's own rim highlight is not enough for the panel edge to read.
    /// Light keeps the airy frost, no extra stroke.
    ///
    /// macOS < 26 fallback: `NSVisualEffectView` blur (`.popover` — cleaner than the
    /// retired `.hudWindow` and its grey wash) under a deep `glassBackdropTint`
    /// (raised to a 70% floor in dark for the same round-5 reason), clipped to the
    /// shape, with the hairline `glassStroke` border as before.
    func glassSurface(
        cornerRadius: CGFloat,
        material: NSVisualEffectView.Material = .popover
    ) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, material: material))
    }

    /// Floating glass panel shadow (see `Theme.Shadows.floatingPanel`).
    func floatingPanelShadow() -> some View {
        Theme.Shadows.floatingPanel(self)
    }
}

/// Implementation of `glassSurface` — a ViewModifier so the glass variant can read
/// the resolved color scheme (the panel pins its NSAppearance, so this follows the
/// in-app theme, not the system one).
struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = .popover

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // .regular in BOTH schemes (round 5): the frost is the luminance
            // floor; the tint is the tone. See the notes on `liquidGlassTint`.
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(Theme.Colors.liquidGlassTint), in: shape)
                .overlay {
                    // Dark-only safety hairline (round 5): over a white backdrop
                    // the material's own rim highlight vanishes — the ink stroke
                    // keeps the panel edge legible. Light keeps the native rim
                    // alone (a stroke on top of it reads as a double border).
                    if colorScheme == .dark {
                        shape.strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
                    }
                }
        } else {
            content
                .background(
                    ZStack {
                        Theme.Glass.GlassBackground(material: material)
                        Theme.Colors.glassBackdropTint
                    }
                )
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.Colors.glassStroke, lineWidth: 1))
        }
    }
}

// MARK: - Color Helpers

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    /// Creates a color that adapts to the current appearance (light/dark mode).
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }
}
