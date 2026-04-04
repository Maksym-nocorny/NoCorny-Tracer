import SwiftUI
import CoreText

// MARK: - Theme

/// Centralized design system tokens aligned with the NoCorny Agency Design System.
enum Theme {

    // MARK: - Colors

    enum Colors {
        // Brand
        static let brandPurple = Color(hex: 0x3E0693)
        static let lightPurple = Color(hex: 0x6B00DE)
        static let pink = Color(hex: 0xFF08DE)
        static let orange = Color(hex: 0xFF6900)
        static let yellow = Color(hex: 0xFFC72C)
        static let red = Color(hex: 0xF9423A)
        static let green = Color(hex: 0x00C040)

        // Backgrounds (Design System semantic)
        static let backgroundPrimary = Color.white               // #ffffff
        static let backgroundSecondary = Color(hex: 0xEEEEEE)    // --neutral-lightest
        static let cardBackground = Color(hex: 0xF5F3F7)         // --neutral-purple (contrast-enhanced)

        // Neutrals
        static let neutralBackground = Color(hex: 0xF5F3F7)
        static let textPrimary = Color(hex: 0x212121)
        static let textAlternate = Color.white

        // Gradients
        static let primaryGradient = LinearGradient(
            colors: [brandPurple, lightPurple],
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

            // Mulish is a variable font (single file), PT Sans has regular + bold
            let fontFiles = ["Mulish", "PTSans-Regular", "PTSans-Bold"]

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
            LogManager.shared.log("Font check — Mulish available: \(hasMulish), PT Sans available: \(hasPTSans)")
        }

        /// Whether the custom Mulish font is available.
        private static var hasMulish: Bool {
            NSFont(name: "Mulish-ExtraLight", size: 12) != nil
        }

        /// Whether the custom PT Sans font is available.
        private static var hasPTSans: Bool {
            NSFont(name: "PTSans-Regular", size: 12) != nil
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
    }

    // MARK: - Animation

    enum Anim {
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let smooth: SwiftUI.Animation = .easeInOut(duration: 0.5)
    }
}

// MARK: - Card ViewModifier

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.xl)
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
}

// MARK: - Color Hex Initializer

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
}
