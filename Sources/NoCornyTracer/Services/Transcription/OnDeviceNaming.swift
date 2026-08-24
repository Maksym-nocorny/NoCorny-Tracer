import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Titles a recording using the language model that ships with macOS 26.
///
/// Tried before Gemini because it is free, private and needs no download -- the model is
/// already on the machine as part of the OS. It is not a replacement: the deployment
/// target is macOS 14, Apple Intelligence can be switched off, and the model can decline
/// a request. Every one of those falls through to the cloud, which is why this returns an
/// optional rather than throwing.
///
/// It sees only the transcript. The cloud path can also send video frames, so on a
/// recording where the words say little and the screen says everything, the cloud title
/// will still be the better one.
enum OnDeviceNaming {

    /// Long enough to characterise the recording, short enough to stay well inside the
    /// model's context. Titles come from the opening anyway.
    private static let maxTranscriptChars = 4000

    /// Whether a title can be produced right now. Cheap, and worth checking before
    /// building a prompt.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    /// A human-readable reason when it is not available, for the log and for Settings.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .deviceNotEligible: return "this Mac does not support Apple Intelligence"
            case .modelNotReady: return "the system model is still downloading"
            @unknown default: return "unavailable"
            }
        @unknown default:
            return "unavailable"
        }
        #else
        return "built without FoundationModels"
        #endif
    }

    /// Whether the on-device model should be asked to title this transcript at all.
    ///
    /// It refuses Ukrainian and Russian on a good day - and on a bad one it does something
    /// worse than refuse: it answers, in English. The first Cyrillic recording after 3.17.0
    /// shipped came back titled "Working on new design concepts with the trainer" - wrong
    /// language, and "трейсер" mistranslated into a gym instructor - while the transcript
    /// itself was flawless. A cloud title in the right language beats a local one in the
    /// wrong language, so anything non-Latin goes straight to Gemini, which is explicitly
    /// told what language to answer in.
    static func canTitle(transcript: String) -> Bool {
        LanguageDetection.dominantScript(transcript) == .latin
    }

    /// Returns a title, or nil to mean "ask the cloud instead".
    static func title(fromTranscript transcript: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        guard canTitle(transcript: transcript) else {
            LogManager.shared.log("🍎 Naming: ⏭️ transcript is not Latin-script — asking the cloud for the title")
            return nil
        }

        let text = String(transcript.prefix(maxTranscriptChars))
        guard text.count > 40 else { return nil }

        let prompt = """
        Below is the transcript of a screen recording. Give it a short descriptive title \
        naming what the recording is about.

        Rules:
        - At most 8 words.
        - Write it in the same language as the transcript.
        - No quotation marks, no trailing full stop, no preamble.
        - Describe the subject, not the format: not "Screen recording" or "Transcript".

        Transcript:
        \(text)
        """

        do {
            let session = LanguageModelSession()
            let started = Date()
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 40)
            )
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let cleaned = clean(response.content) else {
                LogManager.shared.log("🍎 Naming: on-device returned nothing usable, falling back")
                return nil
            }
            LogManager.shared.log("🍎 Naming: ✅ on-device title in \(elapsed)ms")
            return cleaned
        } catch let error as LanguageModelSession.GenerationError {
            // Worth telling apart in a bug report. The common one by far is language:
            // Apple Intelligence covers a fixed list that does not include Ukrainian or
            // Russian, so for a Ukrainian or Russian recording this path will always
            // decline and the cloud will always name it. That is working as intended, not
            // a fault, and the log should not read like one.
            switch error {
            case .unsupportedLanguageOrLocale:
                LogManager.shared.log("🍎 Naming: on-device does not support this language - naming in the cloud")
            case .guardrailViolation:
                LogManager.shared.log("🍎 Naming: on-device declined the transcript - naming in the cloud")
            case .exceededContextWindowSize:
                LogManager.shared.log("🍎 Naming: transcript too long for the on-device model - naming in the cloud")
            default:
                LogManager.shared.log("🍎 Naming: on-device failed (\(error)) - naming in the cloud")
            }
            return nil
        } catch {
            LogManager.shared.log("🍎 Naming: on-device failed (\(error)) - naming in the cloud")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Small models like to answer in a sentence. Strip the packaging, and reject anything
    /// that is clearly not a title rather than shipping a paragraph as one.
    static func clean(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = name.split(separator: "\n").first { name = String(firstLine) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”*# "))
        while let last = name.last, last == "." || last == ":" {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespaces)

        guard name.count >= 3, name.count <= 120 else { return nil }
        // A refusal or an explanation, not a title.
        let lower = name.lowercased()
        for tell in ["i can't", "i cannot", "sorry", "as an ai", "here is", "here's", "title:"] {
            if lower.hasPrefix(tell) { return nil }
        }
        return name
    }
}
