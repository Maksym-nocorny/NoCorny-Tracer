import SwiftUI

/// Confirmation sheet shown after a successful Dropbox OAuth connection
struct DropboxConnectedView: View {
    let userName: String
    let userEmail: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.green.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.green)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("Dropbox Connected")
                    .font(Theme.Typography.heading(18))
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Your recordings will be automatically uploaded.")
                    .font(Theme.Typography.body(12, weight: .light))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Spacing.lg) {
                Circle()
                    .fill(Theme.Colors.primaryGradient)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(String(userName.prefix(1)))
                            .font(Theme.Typography.body(16, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(userName)
                        .font(Theme.Typography.body(13, weight: .medium))
                    Text(userEmail)
                        .font(Theme.Typography.body(11, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

            Button {
                onDismiss()
            } label: {
                Text("Got it")
                    .font(Theme.Typography.body(13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Theme.Colors.primaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(Theme.Spacing.xxxl)
        .frame(width: 320)
        .background(Theme.Colors.backgroundPrimary)
    }
}
