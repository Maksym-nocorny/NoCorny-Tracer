import SwiftUI

/// The two onboarding cards of the redesign (Figma 86:551): a 560pt glass card,
/// no title bar — the window behind it is borderless and transparent.
///
/// Step 1 ("One permission to start") asks for Screen Recording only: mic and
/// camera are deliberately absent, macOS prompts for them on first use. The grant
/// takes effect after a relaunch, so once the permission flips the Grant button
/// becomes "Relaunch to finish". Step 2 ("Where should clips live?") offers the
/// Google sign-in or "Skip for now".
struct OnboardingView: View {
    @Bindable var appState: AppState
    @Bindable var permissionsManager: PermissionsManager
    let manager: OnboardingWindowManager
    let initialStep: OnboardingStep

    @State private var step: OnboardingStep = .permission
    /// True when the permission arrived while the card was up — that grant needs a
    /// relaunch. (Granted BEFORE presentation means a working permission from a
    /// previous run, so step 1 is skipped instead.)
    @State private var grantedThisSession = false

    /// The card sizes of the two steps (Figma 86:551 / 87:561) and the ONE
    /// window box that holds either of them.
    ///
    /// Round 13: the window used to be re-sized by SwiftUI whenever `step`
    /// flipped — the same "hosting view moves its own window from inside the
    /// layout pass" mechanism that crashed the camera bubble in 4.5.0. The
    /// window is now fixed at the taller card plus the shadow apron, and the
    /// card is CENTRED inside it, so the shorter cloud card lands exactly where
    /// a window sized to it would have put it — 10pt of transparent margin is
    /// the whole difference.
    static let cardWidth: CGFloat = 560
    static let permissionCardHeight: CGFloat = 320
    static let cloudCardHeight: CGFloat = 300
    /// Apron the shadow draws into (`.padding(60)` on each side).
    static let shadowApron: CGFloat = 60
    static var windowContentSize: NSSize {
        NSSize(width: cardWidth + shadowApron * 2,
               height: max(permissionCardHeight, cloudCardHeight) + shadowApron * 2)
    }

    var body: some View {
        Group {
            switch step {
            case .permission:
                permissionCard
                    .frame(width: Self.cardWidth, height: Self.permissionCardHeight)
            case .cloud, .none:
                cloudCard
                    .frame(width: Self.cardWidth, height: Self.cloudCardHeight)
            }
        }
        .glassSurface(cornerRadius: 34)
        // Room for the shadow inside the transparent borderless window.
        .floatingPanelShadow()
        .padding(Self.shadowApron)
        // The fixed window box — the card centres in it, and a step change can
        // no longer ask the window to resize itself mid-layout (round 13).
        .frame(width: Self.windowContentSize.width, height: Self.windowContentSize.height)
        .onAppear {
            step = initialStep
            // Permission already working when step 1 comes up → nothing to grant.
            if initialStep == .permission && permissionsManager.isScreenRecordingGranted {
                step = .cloud
            }
        }
        .onChange(of: permissionsManager.isScreenRecordingGranted) { wasGranted, isGranted in
            // Flipped while the card is showing: the grant is real but dead until a
            // relaunch — turn the row green and offer the relaunch, don't advance.
            if step == .permission && !wasGranted && isGranted {
                grantedThisSession = true
            }
        }
        .onChange(of: appState.tracerAPIClient.isSignedIn) { _, isSignedIn in
            if isSignedIn && step == .cloud {
                manager.finish()
            }
        }
    }

    // MARK: - Step 1 · One permission to start (86:554)

    private var permissionCard: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)

            Text("One permission to start")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DrawerStyle.ink(0.95))

            Text("Screen Recording covers your screen and system audio. Your voice (mic) and camera are separate. macOS asks the moment you first use them.")
                .font(.system(size: 12.5))
                .foregroundStyle(DrawerStyle.ink(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(width: 400)

            permissionRow
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 30)
    }

    /// The "Screen Recording / Opens System Settings" row with its Grant button
    /// (86:565). Once granted this session: green check + "Relaunch to finish".
    private var permissionRow: some View {
        HStack(spacing: 12) {
            if grantedThisSession {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Colors.statusGreen)
            } else {
                Image(systemName: "display")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DrawerStyle.ink(0.92))
                Text(grantedThisSession
                     ? "Granted. One relaunch and it takes effect."
                     : "Opens System Settings → Privacy & Security")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.42))
            }

            Spacer(minLength: 24)

            Button {
                if grantedThisSession {
                    manager.relaunch()
                } else {
                    permissionsManager.requestScreenRecording()
                }
            } label: {
                Text(grantedThisSession ? "Relaunch to finish" : "Grant")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.adaptive(light: .white, dark: Color(hex: 0x101013)))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.adaptive(light: Color(hex: 0x0B1220), dark: .white))
                    )
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DrawerStyle.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
        )
    }

    // MARK: - Step 2 · Where should clips live? (86:576)

    private var cloudCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(DrawerStyle.ink(0.9))

            Text("Where should clips live?")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DrawerStyle.ink(0.95))

            Text("Sign in with Google. It links your Dropbox, uploads every clip and hands you a share link. Skip for now? Clips wait locally.")
                .font(.system(size: 12.5))
                .foregroundStyle(DrawerStyle.ink(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(width: 420)

            // Same action as the drawer's sign-in button; sized to the macro (300×44).
            DrawerGoogleSignInButton(
                appState: appState,
                width: 300,
                height: 44,
                cornerRadius: 15,
                showsGlyph: true
            )

            Button {
                manager.finish()
            } label: {
                Text("Skip for now")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 30)
    }
}
