import SwiftUI
import AppKit

// MARK: - Drawer style (Figma 59:3 / 61:66 / 87:708 / 87:561)

/// Shared visual constants of the command-bar drawers. Dark values are measured on
/// the macro frames; light values derive from the ink base #0B1220 the same way the
/// phase-0 glass tokens in Theme.swift do.
enum DrawerStyle {
    /// Corner radius of the drawer glass, measured on the macro (34 — same as the bar).
    static let cornerRadius: CGFloat = 34
    /// Content insets, measured on drawerContent: 16 leading / 12 trailing / 13 top.
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static let topInset: CGFloat = 13
    /// Recording-row corner radius (59:58) and thumbnail radius (59:58;1:186).
    static let rowCornerRadius: CGFloat = 14
    static let thumbCornerRadius: CGFloat = 9

    /// Text/ink on glass at a given opacity, adaptive to the light scheme.
    static func ink(_ opacity: Double) -> Color {
        Color.adaptive(
            light: Color(hex: 0x0B1220, opacity: opacity),
            dark: Color(hex: 0xFFFFFF, opacity: opacity)
        )
    }

    /// Recording-row fill (white 5% in the macro).
    static let rowFill = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.03),
        dark: Color(hex: 0xFFFFFF, opacity: 0.05)
    )
    /// Recording-row border (white 8%) — same value as the phase-0 subtle stroke.
    static let rowStroke = Theme.Colors.glassStrokeSubtle
    /// Hairline between settings rows (white 6%, node 61:150).
    static let hairline = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.04),
        dark: Color(hex: 0xFFFFFF, opacity: 0.06)
    )
    /// Top border of the drawer footer (white 7%, node 59:118).
    static let footerBorder = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.05),
        dark: Color(hex: 0xFFFFFF, opacity: 0.07)
    )
    /// Thumbnail placeholder fill (#222834 in the macro).
    static let thumbFill = Color.adaptive(
        light: Color(hex: 0xE4E7EE),
        dark: Color(hex: 0x222834)
    )

    // MARK: Drawer controls (macro "Pop-Up Button" Medium / "Toggles - Switches")
    // Dark values measured on the 61:66 macro pixels (capsule #272727 over glass
    // #1A1A1D ≈ white 8%); light derives from the ink base like everything above.

    /// Fill of the pop-up capsule.
    static let popUpFill = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.05),
        dark: Color(hex: 0xFFFFFF, opacity: 0.08)
    )
    /// Hover/open fill — one step brighter.
    static let popUpFillHover = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.09),
        dark: Color(hex: 0xFFFFFF, opacity: 0.13)
    )
    /// Hairline border of the pop-up capsule.
    static let popUpStroke = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.10),
        dark: Color(hex: 0xFFFFFF, opacity: 0.12)
    )
    /// Track of a switched-off toggle (ON is `Theme.Colors.statusGreen`, as the
    /// macro paints it).
    static let toggleOffTrack = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.12),
        dark: Color(hex: 0xFFFFFF, opacity: 0.14)
    )
}

// MARK: - Footer

/// The shared drawer footer (Figma 59:118 / 76:144): connection status on the left,
/// "~N min left" on the right. One component so Gallery and Settings can't drift.
struct DrawerFooterView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            if appState.dropboxAuthManager.isSignedIn {
                Circle()
                    .fill(Theme.Colors.statusGreen)
                    .frame(width: 7, height: 7)
                Text("Dropbox connected · auto-upload")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            } else {
                Circle()
                    .fill(Theme.Colors.pausedAmber)
                    .frame(width: 7, height: 7)
                // Same action as the old MainView footer's "Connect Dropbox on Web".
                Button {
                    appState.dropboxAuthManager.signIn()
                } label: {
                    Text("Dropbox not connected · connect on the web ↗")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DrawerStyle.ink(0.5))
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }

            Spacer(minLength: 8)

            if appState.dropboxAuthManager.isSignedIn && appState.dropboxAllocatedSpace > 0 {
                let minutes = DropboxQuota.minutesLeft(
                    used: appState.dropboxUsedSpace,
                    allocated: appState.dropboxAllocatedSpace
                )
                Text("~\(minutes) min left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.35))
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 11)
        .padding(.trailing, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DrawerStyle.footerBorder)
                .frame(height: 1)
        }
    }
}

// MARK: - Section header

/// Small tracked all-caps section title ("RECORDING" / "ACCOUNT" / "GENERAL"),
/// measured on node 61:134: 9.5pt semibold, +1.33 tracking, ink 35%.
struct DrawerSectionHeader: View {
    let title: String
    var topPadding: CGFloat = 14

    var body: some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.33)
            .foregroundStyle(DrawerStyle.ink(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPadding)
            .padding(.bottom, 6)
    }
}

// MARK: - Google sign-in button

/// The 260×40 sign-in button from the signed-out drawer (87:703). White on dark
/// glass in the macro; inverted to ink-on-light in the light scheme. The onboarding
/// card (86:585) reuses it at 300×44 with the "G" glyph — same action, same colors.
struct DrawerGoogleSignInButton: View {
    @Bindable var appState: AppState
    var width: CGFloat = 260
    var height: CGFloat = 40
    var cornerRadius: CGFloat = 14
    var showsGlyph: Bool = false

    var body: some View {
        Button {
            appState.tracerAPIClient.errorMessage = nil
            appState.tracerAPIClient.startBrowserSignIn()
        } label: {
            HStack(spacing: 9) {
                if showsGlyph {
                    Text("G")
                        .font(.system(size: 15, weight: .bold))
                }
                Text("Sign in with Google")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.adaptive(light: .white, dark: Color(hex: 0x101013)))
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.adaptive(light: Color(hex: 0x0B1220), dark: .white))
            )
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }
}

// MARK: - Hover cursor

extension View {
    /// Pointing-hand cursor on hover (drawer counterpart of the bar's private helper).
    func pointerOnHover() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
