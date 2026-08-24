import Foundation

// How close the Dropbox quota is to running out — the pure decision behind the amber
// storage banner under the command bar (Figma macro 87:1810). Computed from the same
// used/allocated pair the drawer footer reads (`AppState.dropboxUsedSpace` /
// `dropboxAllocatedSpace`, refreshed by `reloadRecordingsFromTracer`).

enum StorageAlertLevel: Equatable {
    /// Enough room — no banner.
    case ok
    /// Less than 10% of the allocation left: "Dropbox almost full — ~N min left".
    case low(minutesLeft: Int)
    /// Nothing left: "Dropbox full — recording will be saved locally".
    case full
}

enum StorageAlert {
    /// Less than this fraction of the allocation remaining turns the banner on
    /// (macro 87:1858: "Менше 10% місця: амбер-рядок під баром ДО старту запису").
    static let lowSpaceFraction = 0.10

    /// nil/zero allocation reads as "quota unknown" (signed out, or the envelope has
    /// not arrived yet) — no banner, because an alarm about numbers we don't have
    /// would cry wolf on every fresh install.
    static func level(used: UInt64?, allocated: UInt64?) -> StorageAlertLevel {
        guard let allocated, allocated > 0 else { return .ok }
        let used = used ?? 0
        guard used < allocated else { return .full }
        let remainingFraction = (Double(allocated) - Double(used)) / Double(allocated)
        guard remainingFraction < lowSpaceFraction else { return .ok }
        return .low(minutesLeft: DropboxQuota.minutesLeft(used: used, allocated: allocated))
    }
}
