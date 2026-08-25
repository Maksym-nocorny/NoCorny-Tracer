import SwiftUI
import AppKit

// MARK: - Pointer-on-hover (round 3: one modifier for the whole app)

extension View {
    /// Pointing-hand cursor over an interactive element — THE one door for every
    /// button, row, link, toggle and pop-up in the app (round 3 verdict: the cursor
    /// must flip on all interactive surfaces). Previously three private copies of
    /// the same 3-line helper lived in CommandBarView, RecordingPillView and
    /// DrawerChrome, plus inline `onHover` blocks elsewhere — all now route here.
    ///
    /// `enabled: false` keeps the arrow (e.g. a gallery row with no share link yet)
    /// without the caller having to fork its modifier chain.
    ///
    /// macOS 15+: the native `.pointerStyle(.link)` — AppKit owns the cursor for
    /// exactly as long as the pointer is over the view, so a control that vanishes
    /// mid-hover (the trash button swapping into "Discard?") can't strand a hand
    /// cursor. Fallback (macOS 14): NSCursor push/pop with the push/pop balance
    /// tracked explicitly — `onHover(false)` after a never-pushed enter, or a view
    /// disappearing while hovered, must not pop someone else's cursor or leak ours.
    func pointerOnHover(_ enabled: Bool = true) -> some View {
        modifier(PointerOnHoverModifier(enabled: enabled))
    }
}

private struct PointerOnHoverModifier: ViewModifier {
    var enabled: Bool

    /// Fallback-path bookkeeping: whether WE pushed the cursor that is now on top.
    @State private var pushed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? .link : .default)
        } else {
            content
                .onHover { inside in
                    if inside, enabled {
                        if !pushed {
                            NSCursor.pointingHand.push()
                            pushed = true
                        }
                    } else if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onDisappear {
                    // The hovered control can be removed from the hierarchy without a
                    // final onHover(false) — e.g. the pill's trash → "Discard?" swap.
                    if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
        }
    }
}
