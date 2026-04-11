import SwiftUI

// MARK: - Data Types

/// A single option in a custom dropdown menu
struct DropdownOption<Value: Hashable>: Identifiable {
    let id: String
    let label: String
    let value: Value
}

/// Type-erased option item for the overlay (no generics needed)
struct DropdownOptionItem: Identifiable {
    let id: String
    let label: String
    let isSelected: Bool
}

/// Anchor data for positioning the dropdown menu relative to its trigger button
struct DropdownAnchorData {
    let id: String
    let anchor: Anchor<CGRect>
    let options: [DropdownOptionItem]
    let onSelect: (String) -> Void
}

/// Preference key that collects anchor data from all dropdown buttons in the view hierarchy
struct DropdownAnchorKey: PreferenceKey {
    static var defaultValue: [DropdownAnchorData] = []
    static func reduce(value: inout [DropdownAnchorData], nextValue: () -> [DropdownAnchorData]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Trigger Button

/// The inline trigger button that replaces the system Picker
struct CustomDropdownButton<Value: Hashable>: View {
    let id: String
    let options: [DropdownOption<Value>]
    @Binding var selection: Value
    @Binding var activeDropdownID: String?
    var minWidth: CGFloat = 120

    @State private var isHovered = false

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    private var isActive: Bool {
        activeDropdownID == id
    }

    var body: some View {
        Button {
            withAnimation(Theme.Anim.standard) {
                activeDropdownID = isActive ? nil : id
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(selectedLabel)
                    .font(Theme.Typography.body(12))
                    .foregroundStyle(Theme.Colors.brandPurple)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Colors.brandPurple.opacity(0.6))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs + 1)
            .frame(minWidth: minWidth, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.brandPurple.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        isActive ? Theme.Colors.brandPurple.opacity(0.4) : Theme.Colors.brandPurple.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { anchor in
            [DropdownAnchorData(
                id: id,
                anchor: anchor,
                options: options.map { opt in
                    DropdownOptionItem(id: opt.id, label: opt.label, isSelected: opt.value == selection)
                },
                onSelect: { selectedID in
                    if let option = options.first(where: { $0.id == selectedID }) {
                        selection = option.value
                    }
                }
            )]
        }
    }
}

// MARK: - Dropdown Overlay

/// Renders the floating dropdown menu and dismiss background.
/// Place this once on the SettingsView via `.overlayPreferenceValue`.
struct CustomDropdownOverlay: View {
    let anchors: [DropdownAnchorData]
    @Binding var activeDropdownID: String?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        GeometryReader { proxy in
            if let activeID = activeDropdownID,
               let data = anchors.first(where: { $0.id == activeID }) {
                let triggerRect = proxy[data.anchor]

                // Full-area dismiss background
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.Anim.standard) {
                            activeDropdownID = nil
                        }
                    }

                // Options menu
                dropdownMenu(data: data, triggerRect: triggerRect)
            }
        }
        .allowsHitTesting(activeDropdownID != nil)
    }

    @ViewBuilder
    private func dropdownMenu(data: DropdownAnchorData, triggerRect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.options) { option in
                DropdownOptionRow(
                    option: option,
                    onSelect: {
                        data.onSelect(option.id)
                        withAnimation(Theme.Anim.standard) {
                            activeDropdownID = nil
                        }
                    }
                )
            }
        }
        .frame(minWidth: triggerRect.width)
        .background(Theme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                    lineWidth: 1
                )
        )
        .designShadowDropdown()
        .position(
            x: triggerRect.midX,
            y: triggerRect.maxY + menuHeight(optionCount: data.options.count) / 2 + 4
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private func menuHeight(optionCount: Int) -> CGFloat {
        CGFloat(optionCount) * 28
    }
}

// MARK: - Option Row

private struct DropdownOptionRow: View {
    let option: DropdownOptionItem
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.brandPurple)
                    .opacity(option.isSelected ? 1 : 0)
                    .frame(width: 14)

                Text(option.label)
                    .font(Theme.Typography.body(12))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm - 2)
                    .fill(isHovered ? Theme.Colors.brandPurple.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Settings Button Style

/// A purple pill button style matching the custom dropdown buttons.
/// Use on small action buttons in Settings (Sign Out, Open, Permissions, Show Logs).
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body(12))
            .foregroundStyle(Theme.Colors.brandPurple)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs + 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.brandPurple.opacity(configuration.isPressed ? 0.18 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.Colors.brandPurple.opacity(0.15), lineWidth: 1)
            )
    }
}

// MARK: - View Extension

extension View {
    /// Adds the dropdown overlay to a container view.
    /// Place this on the outermost view that should allow dropdowns to escape card clipping.
    func customDropdownOverlay(activeDropdownID: Binding<String?>) -> some View {
        self.overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
            CustomDropdownOverlay(anchors: anchors, activeDropdownID: activeDropdownID)
        }
    }
}
