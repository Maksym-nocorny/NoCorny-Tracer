import Foundation
import Observation

/// What the UI shows about the on-device Whisper model.
///
/// The engine itself keeps no observable state: `isModelDownloaded()` is a filesystem check
/// that has to answer synchronously from `isReady`, on whatever thread asks. This is the
/// main-actor mirror of that, written only by `LocalWhisperEngine` through the `push`
/// helpers so SwiftUI has something to observe.
///
/// `preparing` is the case that earns its keep. After the ~1.5 GB of model bytes land there
/// is a silent stretch (tokenizer fetch, then the one-time Core ML compile) with no progress
/// callbacks at all, which on a slow Mac runs for minutes. Corder shipped that as a progress
/// bar pinned at 99% and users read it as a hang, so the phase is explicit here and
/// `downloadProgress` goes back to nil rather than freezing near the end.
@MainActor
@Observable
final class LocalModelState {

    enum Phase: Equatable {
        case notDownloaded
        case downloading
        /// Bytes are in. Staging the tokenizer and compiling for the Neural Engine, neither
        /// of which reports progress. Show something indeterminate, not a stalled bar.
        case preparing
        /// A complete, loadable model is on disk.
        case ready
        case failed(String)
    }

    static let shared = LocalModelState()

    private(set) var isDownloaded: Bool = false
    /// 0.0 to 1.0 while bytes are moving, nil otherwise (including during `preparing`).
    private(set) var downloadProgress: Double?
    private(set) var phase: Phase = .notDownloaded

    private init() {
        refresh()
    }

    /// Re-reads the model folder. Cheap, and the only way to notice a model that was
    /// deleted from disk behind the app's back. Leaves `phase` alone while a download or a
    /// prepare is running, since those know more about the model than the filesystem does.
    func refresh() {
        isDownloaded = LocalWhisperEngine.isModelDownloaded()
        guard downloadProgress == nil, phase != .preparing else { return }
        settle()
    }

    private func settle() {
        isDownloaded = LocalWhisperEngine.isModelDownloaded()
        phase = isDownloaded ? .ready : .notDownloaded
    }

    // MARK: - Writers

    nonisolated static func push(progress: Double?) {
        Task { @MainActor in
            shared.downloadProgress = progress
            if progress != nil {
                shared.phase = .downloading
            } else {
                shared.refresh()
            }
        }
    }

    nonisolated static func push(preparing: Bool) {
        Task { @MainActor in
            if preparing {
                shared.downloadProgress = nil
                shared.phase = .preparing
            } else {
                shared.settle()
            }
        }
    }

    nonisolated static func pushFailure(_ message: String) {
        Task { @MainActor in
            shared.downloadProgress = nil
            shared.isDownloaded = LocalWhisperEngine.isModelDownloaded()
            shared.phase = .failed(message)
        }
    }

    nonisolated static func pushRefresh() {
        Task { @MainActor in shared.refresh() }
    }
}
