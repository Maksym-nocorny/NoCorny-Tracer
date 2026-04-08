import SwiftUI

public enum DesignSystem {
    
    // MARK: - Colors
    public enum Colors {
        // Brand Scale
        public static let brandPurple = Color(hex: "#3e0693")
        public static let brandLightPurple = Color(hex: "#6b00de")
        public static let brandPink = Color(hex: "#ff08de")
        public static let brandOrange = Color(hex: "#ff6900")
        public static let brandYellow = Color(hex: "#ffc72c")
        
        // System
        public static let successGreen = Color(hex: "#00c040")
        public static let errorRed = Color(hex: "#f9423a")
        
        // Neutral Scale (Hardcoded to Light Mode as per request)
        public static let backgroundNeutral = Color(hex: "#fbf9fd") // neutral-purple
        public static let backgroundWhite = Color(hex: "#ffffff")
        public static let backgroundLightest = Color(hex: "#eeeeee")
        public static let backgroundLighter = Color(hex: "#cccccc")
        public static let backgroundLight = Color(hex: "#aaaaaa")
        
        // Text Colors
        public static let textPrimary = Color(hex: "#212121") // black
        public static let textSecondary = Color(hex: "#444444") // dark
        public static let textTertiary = Color(hex: "#666666") // base neutral
    }
    
    // MARK: - Spacing (1rem = 16pt)
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let base: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 40
        public static let xxxl: CGFloat = 64
    }
    
    // MARK: - Radius
    public enum Radius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 40
        public static let pill: CGFloat = .infinity
    }
    
    // MARK: - Fonts
    // Using SF Pro as fallback with similar weights to Mulish/PTSans if not loaded
    public enum Typography {
        public static func heading(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            return .custom("PTSans-Bold", size: size).fallback(.system(size: size, weight: weight, design: .serif))
        }
        
        public static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            let fontName: String
            switch weight {
            case .light: fontName = "Mulish-Light"
            case .medium: fontName = "Mulish-Medium"
            case .semibold: fontName = "Mulish-SemiBold"
            case .bold: fontName = "Mulish-Bold"
            default: fontName = "Mulish-Regular"
            }
            return .custom(fontName, size: size).fallback(.system(size: size, weight: weight, design: .default))
        }
    }
}

// Custom Font Fallback helper
extension Font {
    func fallback(_ fallbackFont: Font) -> Font {
        // Form SwiftUI, missing custom fonts just revert to `.system` naturally
        return self
    }
}

// Hex Color Initializer
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Shadow Modifiers
public struct BaseShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

public struct CardShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 4)
            .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 2)
    }
}

public struct CardHoverShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 12)
            .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 4)
    }
}

public struct DropdownShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 20)
            .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 8)
    }
}

public extension View {
    func designShadowBase() -> some View {
        modifier(BaseShadow())
    }
    
    func designShadowCard() -> some View {
        modifier(CardShadow())
    }
    
    func designShadowCardHover() -> some View {
        modifier(CardHoverShadow())
    }
    
    func designShadowDropdown() -> some View {
        modifier(DropdownShadow())
    }
}
