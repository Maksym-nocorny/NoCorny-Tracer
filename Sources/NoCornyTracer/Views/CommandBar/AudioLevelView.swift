import SwiftUI

// Evacuated from Views/RecordingControlsView.swift when phase 7 dismantled the
// main window. Nothing in the bar uses them at the moment; they are the reusable
// live-level and pulse primitives the pill/bar can pick up (e.g. a mic level in
// the recording pill), and they carry recording-UI history worth keeping.

// MARK: - Audio Level View

/// A slim horizontal level meter: green → yellow → red as the level rises.
struct AudioLevelView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 { return Theme.Colors.red }
        if level > 0.5 { return Theme.Colors.yellow }
        return Theme.Colors.green
    }
}

// MARK: - Pulsing Modifier

/// Slow opacity pulse for "recording" dots.
struct PulsingModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && isPulsing ? 0.3 : 1.0)
            .animation(isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
            .onAppear { isPulsing = isActive }
            // Re-arm the repeating animation when isActive flips back on. Previously
            // the pulse only started in onAppear, so after a pause→resume (isActive
            // false→true) the dot stayed frozen.
            .onChange(of: isActive) { _, active in isPulsing = active }
    }
}
