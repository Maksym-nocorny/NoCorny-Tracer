import AppKit

/// Simple manager for playing macOS system sounds
final class SoundManager {
    static let shared = SoundManager()
    
    enum AppSound: String {
        case start = "Hero"
        case stop = "Submarine"
        case abort = "Basso"
        case pause = "Tink"
    }

    private init() {}

    /// Plays a system sound by name
    /// - Parameter sound: The AppSound to play
    func play(_ sound: AppSound) {
        // NSSound(named:) looks for system sounds in /System/Library/Sounds/
        // as well as the app's bundle and several other locations.
        if let nsSound = NSSound(named: sound.rawValue) {
            nsSound.play()
        }
    }
}
