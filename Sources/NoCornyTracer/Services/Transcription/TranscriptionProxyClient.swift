import Foundation

/// HTTP client for the speech-to-text proxy at tracer.nocorny.com.
///
/// Its own type rather than a method on GeminiProxyClient: that client speaks JSON to a
/// hardcoded Gemini path and inlines media as base64, which inflates the audio by a third
/// on exactly the path where the request-body ceiling bites hardest. A Whisper-style
/// endpoint takes the file as raw multipart bytes instead, so the two share nothing below
/// the bearer token and the size guard.
final class TranscriptionProxyClient {

    /// The same ceiling GeminiProxyClient enforces, for the same reason: the proxy runs as
    /// a Vercel serverless function, and Vercel rejects bodies over 4.5 MB at the edge
    /// BEFORE the handler runs, so the server can never answer with anything useful.
    /// Measured against the ASSEMBLED body -- boundaries, part headers and the prompt field
    /// all travel with the audio, and a guard that only weighed the audio would let a
    /// borderline chunk through to a 413 nobody can explain.
    static let maxRequestBodyBytes = GeminiProxyClient.maxRequestBodyBytes

    /// Whisper's `prompt` is a spelling reference, not an instruction channel, and the
    /// server rejects anything longer. Trimmed here so an oversized glossary costs a
    /// truncation rather than the whole request.
    static let maxPromptCharacters = 900

    private let baseURL: String
    private let tokenProvider: () -> String?

    init(
        baseURL: String = TracerAPIClient.baseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// True when a Tracer bearer token is available. Callers check this before starting
    /// expensive prep work (audio extraction, VAD, chunk encodes) so a signed-out user
    /// fails immediately instead of a minute in.
    var isReady: Bool { tokenProvider() != nil }

    /// Uploads one audio file and returns Groq's `verbose_json` transcription.
    ///
    /// - Parameter language: an explicit language code, or nil to let the model decide.
    /// - Parameter prompt: names the model should spell a particular way. Truncated to
    ///   `maxPromptCharacters`.
    func transcribe(
        audio: Data,
        filename: String = "audio.m4a",
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> ProxyTranscription {
        guard let token = tokenProvider() else {
            throw ProxyTranscriptionError.notSignedIn
        }

        let boundary = "NCTBoundary-\(UUID().uuidString)"
        let httpBody = Self.multipartBody(
            boundary: boundary, audio: audio, filename: filename,
            language: language, prompt: prompt
        )

        // Logged unconditionally so payload size stays observable in production, the same
        // way the Gemini client reports its serialized body.
        LogManager.shared.log("🎧 Groq proxy: request body \(httpBody.count / 1024)KB")
        guard httpBody.count <= Self.maxRequestBodyBytes else {
            LogManager.shared.log(
                "🎧 Groq proxy: ❌ Request body \(httpBody.count / 1024)KB exceeds \(Self.maxRequestBodyBytes / 1024)KB limit, not sending",
                type: .error
            )
            // 413 is exactly what the edge would have answered, so the caller sees one
            // status code for "too big" whether we caught it or Vercel did.
            throw ProxyTranscriptionError.fatal(
                status: 413,
                message: "request body \(httpBody.count / 1024)KB exceeds the \(Self.maxRequestBodyBytes / 1024)KB limit"
            )
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/api/groq/transcribe")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GeminiProxyClient.appVersion, forHTTPHeaderField: "X-Tracer-App-Version")
        request.timeoutInterval = 120
        request.httpBody = httpBody

        let startedAt = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw ProxyTranscriptionError.transient(status: 0)
        }
        guard http.statusCode == 200 else {
            throw Self.mapFailure(status: http.statusCode, data: data)
        }

        guard let decoded = try? JSONDecoder().decode(VerboseJSON.self, from: data) else {
            // A 200 whose body will not decode is a truncated or garbled response, not a
            // verdict about the audio, so it is worth one more roll -- the Gemini client
            // treats its own unusable-body case the same way.
            LogManager.shared.log("🎧 Groq proxy: ⚠️ 200 with an undecodable body (\(data.count) bytes)", type: .error)
            throw ProxyTranscriptionError.transient(status: 200)
        }

        return ProxyTranscription(
            text: decoded.text ?? "",
            duration: decoded.duration ?? 0,
            segments: decoded.segments ?? [],
            latencyMs: latencyMs
        )
    }

    // MARK: - Body

    /// Builds the multipart body by hand. URLSession has no multipart encoder, and the
    /// alternatives all copy the audio one more time for a format that is four lines of
    /// string concatenation around a single `Data` append.
    static func multipartBody(
        boundary: String,
        audio: Data,
        filename: String,
        language: String?,
        prompt: String?
    ) -> Data {
        var body = Data()

        body.appendText("--\(boundary)\r\n")
        body.appendText("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        // The audio is always the 32 kbps mono m4a AudioPreparation produces, so the type
        // is pinned rather than sniffed.
        body.appendText("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.appendText("\r\n")

        func appendField(_ name: String, _ value: String) {
            body.appendText("--\(boundary)\r\n")
            body.appendText("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendText("\(value)\r\n")
        }
        if let language, !language.isEmpty {
            appendField("language", language)
        }
        if let prompt, !prompt.isEmpty {
            appendField("prompt", String(prompt.prefix(maxPromptCharacters)))
        }

        body.appendText("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Failures

    /// Turns a non-200 into the one error case that describes what actually happened.
    ///
    /// The two coded answers are the ones worth telling apart: `premium_required` is a
    /// property of the account and will never change on retry, while `engine_disabled` is
    /// an admin switch that says nothing about this recording and should send the caller
    /// looking for another engine rather than giving up.
    static func mapFailure(status: Int, data: Data) -> ProxyTranscriptionError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = json?["code"] as? String
        let rawMessage = (json?["error"] as? String)
            ?? (json?["message"] as? String)
            ?? String(data: data, encoding: .utf8)
            ?? ""
        let message = String(rawMessage.prefix(200))

        switch status {
        case 403 where code == "premium_required":
            return .premiumRequired
        case 503 where code == "engine_disabled":
            return .engineDisabled
        case 408, 429, 500...599:
            // Everything else in the 5xx band, 502 included, is the proxy or Groq itself
            // being briefly unavailable. An upstream rate limit arrives here too.
            return .transient(status: status)
        default:
            return .fatal(status: status, message: message)
        }
    }

    // MARK: - Wire format

    /// Only the fields we use. Groq's `verbose_json` carries more per segment (id, seek,
    /// token ids, no-speech probabilities); decoding ignores what is not declared here, so
    /// the server adding fields cannot break the client.
    private struct VerboseJSON: Decodable {
        let text: String?
        let duration: Double?
        let segments: [ProxyTranscriptionSegment]?
    }
}

// MARK: - Result types

/// One cue as Groq reports it.
///
/// `start` and `end` are SECONDS from the beginning of the audio that was SUBMITTED. On a
/// chunked run that means clip-local, not recording-local: projecting them back onto the
/// original timeline is the caller's job and is the single easiest thing to get wrong on
/// this path, because a cue that is off by a chunk offset still looks perfectly valid.
struct ProxyTranscriptionSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
}

/// One transcription call's result plus measured latency.
struct ProxyTranscription {
    let text: String
    let duration: Double
    let segments: [ProxyTranscriptionSegment]
    let latencyMs: Int
}

// MARK: - Errors

enum ProxyTranscriptionError: LocalizedError {
    /// No Tracer token at all, so there is nothing to authenticate with.
    case notSignedIn
    /// The account is not entitled to cloud transcription (403 `premium_required`).
    case premiumRequired
    /// An admin turned this engine off server-side (503 `engine_disabled`).
    case engineDisabled
    /// The proxy or Groq was briefly unavailable, an upstream rate limit included.
    case transient(status: Int)
    /// A deterministic refusal: the request itself is wrong, or the token is not accepted.
    case fatal(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Tracer, cloud transcription requires an account"
        case .premiumRequired:
            return "Cloud transcription is not included in this plan"
        case .engineDisabled:
            return "Cloud transcription is temporarily switched off"
        case .transient(let status):
            return "Transcription proxy is unavailable (\(status))"
        case .fatal(let status, let message):
            return "Transcription proxy refused the request (\(status)): \(message)"
        }
    }

    /// Short, stable identifier carried into `EngineResult.errorCode` and telemetry.
    var code: String {
        switch self {
        case .notSignedIn: return "not_signed_in"
        case .premiumRequired: return "premium_required"
        case .engineDisabled: return "engine_disabled"
        case .transient(let status): return "groq_transient_\(status)"
        case .fatal(let status, _): return "groq_fatal_\(status)"
        }
    }

    /// Whether sending the SAME request again could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transient:
            return true
        case .notSignedIn, .premiumRequired, .engineDisabled, .fatal:
            return false
        }
    }
}

/// Retryability for an arbitrary error thrown on the transcription path. Anything that is
/// not a `ProxyTranscriptionError` came from URLSession (timeout, dropped connection) and
/// is transient by nature, so it stays retryable -- the same rule the Gemini path uses.
func isRetryableTranscriptionError(_ error: Error) -> Bool {
    (error as? ProxyTranscriptionError)?.isRetryable ?? true
}

private extension Data {
    /// Appends UTF-8 text. Named rather than an `append(_: String)` overload so it cannot
    /// be confused with `Data`'s own byte-sequence appends at a call site.
    mutating func appendText(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
