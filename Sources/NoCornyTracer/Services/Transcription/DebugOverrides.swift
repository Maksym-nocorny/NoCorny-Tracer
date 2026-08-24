import Foundation

/// Diagnostic switches, honoured only in debug builds.
///
/// These are `defaults write` knobs for testing - a lowered chunk target, forced Intel
/// behaviour, a disabled glossary. A release build used to read them too, which turned a
/// leftover test value into production behaviour with no UI showing it: a live-test session
/// left `NCTChunkTargetSecondsOverride = 30` in the REAL preferences domain, and every cloud
/// transcription on that Mac would have quietly run at sixty chunks an hour - billed, slower,
/// and invisible, because nothing on any screen says the knob exists.
enum DebugOverrides {
    /// The override's value in debug builds; always nil in release, whatever is on disk.
    static func double(forKey key: String) -> Double? {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : nil
        #else
        return nil
        #endif
    }

    static func string(forKey key: String) -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: key)
        #else
        return nil
        #endif
    }

    static func bool(forKey key: String) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: key)
        #else
        return false
        #endif
    }
}
