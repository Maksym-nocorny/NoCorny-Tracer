import SwiftUI
import AppKit

// MARK: - Drawer controls (verdict 25.08: «кнопки і перемикачі абсолютно неправильні»)
//
// The Settings drawer used to borrow `CustomDropdownButton` and the system
// `.switch` toggle from the RETIRED main-window design — purple rectangles and
// accent-colored switches on the redesign's ink-on-glass sheet. These are the
// drawer's own controls, built against the macro components on node 61:66:
// "Pop-Up Button" (Medium) → `DrawerPopUp`, "Toggles - Switches" → `DrawerToggle`,
// plus the shared `DrawerLink` for the Sign Out–style text actions.

// MARK: - Pop-up option

/// One choice in a drawer pop-up. Locked options stay visible and explain
/// themselves (`badge` + padlock) instead of quietly not existing — the same
/// contract the old dropdown had.
struct DrawerPopUpOption<Value: Hashable>: Identifiable {
    let id: String
    let label: String
    let value: Value
    var isLocked: Bool = false
    var badge: String? = nil
}

// MARK: - Pop-up button

/// The macro's compact pop-up (measured on 61:66): a 26pt capsule hugging the
/// selected value, up/down chevron, subtle glass fill. The menu opens in an
/// NSPopover styled like the bar's capture-mode menu — the one popover pattern
/// already proven on this nonactivating panel.
struct DrawerPopUp<Value: Hashable>: View {
    let options: [DrawerPopUpOption<Value>]
    @Binding var selection: Value
    /// Called when a locked option is picked, instead of selecting it.
    var onLockedTap: ((Value) -> Void)? = nil

    @State private var isHovering = false
    @State private var showMenu = false

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Button {
            showMenu.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(selectedLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(DrawerStyle.ink(0.55))
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(
                Capsule().fill(
                    isHovering || showMenu ? DrawerStyle.popUpFillHover : DrawerStyle.popUpFill
                )
            )
            .overlay(Capsule().strokeBorder(DrawerStyle.popUpStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerOnHover()
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            DrawerPopUpMenu(
                options: options,
                selectedID: options.first(where: { $0.value == selection })?.id
            ) { option in
                showMenu = false
                if option.isLocked {
                    onLockedTap?(option.value)
                } else {
                    selection = option.value
                }
            }
        }
    }
}

/// The pop-up's menu, in the capture-menu's visual language (CommandBarView's
/// CaptureModeMenu): 224-style compact rows, checkmark trailing the selected one.
private struct DrawerPopUpMenu<Value: Hashable>: View {
    let options: [DrawerPopUpOption<Value>]
    let selectedID: String?
    let onPick: (DrawerPopUpOption<Value>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options) { option in
                Button {
                    onPick(option)
                } label: {
                    HStack(spacing: 8) {
                        Text(option.label)
                            .font(Theme.Typography.body(13))
                            .foregroundStyle(
                                option.isLocked
                                    ? Theme.Colors.textPrimary.opacity(0.55)
                                    : Theme.Colors.textPrimary
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 12)

                        if let badge = option.badge {
                            Text(badge)
                                .font(Theme.Typography.body(10))
                                .foregroundStyle(Theme.Colors.timerDimmed)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.Colors.glassControlFill))
                        }

                        if option.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textPrimary.opacity(0.55))
                        } else if option.id == selectedID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }
        }
        .padding(8)
        .frame(minWidth: 170, alignment: .leading)
    }
}

// MARK: - Toggle

/// The macro's switch ("Toggles - Switches", Medium knob), measured on 61:66:
/// a 54×24 track with a WIDE 30×20 pill knob — deliberately not the system
/// `.switch`, whose accent-colored, smaller shape is what the 25.08 verdict
/// called out. ON is the macro's own green; OFF is an ink track.
struct DrawerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Theme.Anim.standard) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.Colors.statusGreen : DrawerStyle.toggleOffTrack)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white)
                    .frame(width: 30, height: 20)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .frame(width: 54, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }
}

// MARK: - Link

/// The Sign Out–style text action of the drawers (11.5 medium, ink 55% — nodes
/// 61:197 / 61:205 / 527:1608). One component so Remove/Manage/Sign Out and the
/// ABOUT links can't drift apart.
struct DrawerLink: View {
    let title: String
    var opacity: Double = 0.55
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(opacity))
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }
}
