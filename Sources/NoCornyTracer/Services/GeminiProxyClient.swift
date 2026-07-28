import Foundation

/// HTTP client that proxies Gemini API calls through the Tracer web backend.
/// Auth is the per-user bearer token issued at tracer.nocorny.com — the real
/// Gemini API key lives only on the server, so a leaked binary can't burn
/// through the project's billing.
final class GeminiProxyClient {
    /// Hard ceiling on the serialized request body. The proxy runs as a Vercel serverless
    /// function, and Vercel rejects request bodies over 4.5 MB at the edge — BEFORE the
    /// handler runs — with `413 FUNCTION_PAYLOAD_TOO_LARGE`. That means the server can never
    /// return a friendly error or a partial result: the only place this can be caught is here,
    /// client-side, by measuring the body we are about to send. 4.0 MB leaves headroom for
    /// the platform's own accounting and stays safe under either MB or MiB interpretation.
    static let maxRequestBodyBytes = 4_000_000

    private let baseURL: String
    private let tokenProvider: () -> String?

    init(
        baseURL: String = "https://tracer.nocorny.com/api/gemini",
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// True when a Tracer bearer token is available. Callers should check this
    /// before kicking off expensive prep work (audio extraction, frame capture)
    /// to fail fast for signed-out users.
    var isReady: Bool { tokenProvider() != nil }

    // MARK: - Generate Content

    /// Default safety settings — relaxed because we're summarizing the user's own recordings.
    /// If they curse or use rough language, transcription/naming should still go through.
    /// Without this, Gemini's defaults silently return empty responses on transcripts with mat.
    private static let defaultSafetySettings: [[String: Any]] = [
        ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
        ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
        ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
        ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
    ]

    /// Sends a generateContent request to the Gemini proxy.
    /// Returns text + usage metadata + measured latency.
    func generateContent(
        model: String = "gemini-2.5-flash-lite",
        contents: [[String: Any]],
        generationConfig: [String: Any]? = nil
    ) async throws -> GeminiProxyResult {
        guard let token = tokenProvider() else {
            throw ProxyError.notSignedIn
        }

        let url = URL(string: "\(baseURL)/proxy")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120 // Gemini can be slow for large media

        var body: [String: Any] = [
            "model": model,
            "contents": contents,
            "safetySettings": Self.defaultSafetySettings,
        ]
        if let cfg = generationConfig {
            body["generationConfig"] = cfg
        }
        let httpBody = try JSONSerialization.data(withJSONObject: body)

        // Pre-flight size guard. This is the EXACT byte count going over the wire, not an
        // estimate from the media we packed — base64 inflation, JSON escaping and the prompt
        // all land here. Callers budget media conservatively before building the request;
        // this is the backstop that turns a wasted round-trip (and a 413 the server never
        // sees) into a local, non-retryable error. Logged unconditionally so payload size
        // stays observable in production.
        LogManager.shared.log("🤖 Proxy: request body \(httpBody.count / 1024)KB")
        guard httpBody.count <= Self.maxRequestBodyBytes else {
            LogManager.shared.log(
                "🤖 Proxy: ❌ Request body \(httpBody.count / 1024)KB exceeds \(Self.maxRequestBodyBytes / 1024)KB limit — not sending",
                type: .error
            )
            throw ProxyError.payloadTooLarge(bytes: httpBody.count)
        }
        request.httpBody = httpBody

        let startedAt = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProxyError.serverError(status: httpResponse.statusCode, body: bodyStr)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw ProxyError.noTextInResponse
        }

        // Concatenate the text of ALL parts (Gemini can split a single response across
        // multiple text parts, and parts.first alone silently drops the rest). Non-text
        // parts (e.g. inlineData) are skipped. Joining with "" keeps the single-part
        // happy path byte-identical — JSON-mode responses are contiguous, not line-delimited.
        let content = firstCandidate["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let text = (parts ?? [])
            .compactMap { $0["text"] as? String }
            .joined()

        // Empty text means Gemini returned no usable content. Distinguish a deliberate
        // block (SAFETY / RECITATION / promptFeedback.blockReason) from a generic empty
        // response so telemetry and the retry loop see a specific, actionable error.
        if text.isEmpty {
            let blockedReasons: Set<String> = ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST"]
            if let finishReason = firstCandidate["finishReason"] as? String,
               blockedReasons.contains(finishReason) {
                throw ProxyError.blocked(reason: finishReason)
            }
            if let promptFeedback = json["promptFeedback"] as? [String: Any],
               let blockReason = promptFeedback["blockReason"] as? String {
                throw ProxyError.blocked(reason: blockReason)
            }
            throw ProxyError.noTextInResponse
        }

        let usage = GeminiUsage.from(json["usageMetadata"] as? [String: Any])
        let modelVersion = (json["modelVersion"] as? String) ?? model

        return GeminiProxyResult(text: text, usage: usage, model: modelVersion, latencyMs: latencyMs)
    }

    // MARK: - Convenience: Multimodal

    /// Generates content from a text prompt + optional audio + optional images, in a single call.
    /// Used for the combined transcription + naming request.
    func generateMultimodal(
        prompt: String,
        audioData: Data? = nil,
        audioMimeType: String = "audio/mp4",
        images: [Data] = [],
        imageMimeType: String = "image/jpeg",
        generationConfig: [String: Any]? = nil
    ) async throws -> GeminiProxyResult {
        var parts: [[String: Any]] = [["text": prompt]]

        if let audio = audioData {
            parts.append([
                "inlineData": [
                    "mimeType": audioMimeType,
                    "data": audio.base64EncodedString()
                ]
            ])
        }

        for imageData in images {
            parts.append([
                "inlineData": [
                    "mimeType": imageMimeType,
                    "data": imageData.base64EncodedString()
                ]
            ])
        }

        let contents: [[String: Any]] = [["parts": parts]]
        return try await generateContent(contents: contents, generationConfig: generationConfig)
    }

    // MARK: - Convenience: Text + Images (legacy, used for naming-only fallback when no audio)

    /// Generates content from a text prompt and optional inline image data.
    func generateWithImages(prompt: String, images: [Data], mimeType: String = "image/jpeg") async throws -> GeminiProxyResult {
        return try await generateMultimodal(prompt: prompt, images: images, imageMimeType: mimeType)
    }
}

// MARK: - Result types

/// Single Gemini call result with cost-tracking metadata.
struct GeminiProxyResult {
    let text: String
    let usage: GeminiUsage
    let model: String
    let latencyMs: Int
}

/// Token usage breakdown reported by Gemini's `usageMetadata`.
struct GeminiUsage: Equatable {
    var promptTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    /// Per-modality breakdown of `promptTokens` (TEXT / AUDIO / IMAGE / VIDEO).
    var modalityBreakdown: [ModalityTokens]

    static let zero = GeminiUsage(promptTokens: 0, outputTokens: 0, totalTokens: 0, modalityBreakdown: [])

    static func from(_ raw: [String: Any]?) -> GeminiUsage {
        guard let raw else { return .zero }
        let prompt = (raw["promptTokenCount"] as? Int) ?? 0
        let output = (raw["candidatesTokenCount"] as? Int) ?? 0
        let total = (raw["totalTokenCount"] as? Int) ?? (prompt + output)
        var breakdown: [ModalityTokens] = []
        if let details = raw["promptTokensDetails"] as? [[String: Any]] {
            for item in details {
                if let modality = item["modality"] as? String,
                   let count = item["tokenCount"] as? Int {
                    breakdown.append(ModalityTokens(modality: modality, tokenCount: count))
                }
            }
        }
        return GeminiUsage(promptTokens: prompt, outputTokens: output, totalTokens: total, modalityBreakdown: breakdown)
    }

    /// Merges another usage record (used to sum across retries).
    mutating func add(_ other: GeminiUsage) {
        promptTokens += other.promptTokens
        outputTokens += other.outputTokens
        totalTokens += other.totalTokens
        // Sum modality counts by modality name.
        var map: [String: Int] = Dictionary(uniqueKeysWithValues: modalityBreakdown.map { ($0.modality, $0.tokenCount) })
        for m in other.modalityBreakdown {
            map[m.modality, default: 0] += m.tokenCount
        }
        modalityBreakdown = map.map { ModalityTokens(modality: $0.key, tokenCount: $0.value) }
            .sorted { $0.modality < $1.modality }
    }
}

struct ModalityTokens: Equatable {
    let modality: String
    let tokenCount: Int
}

// MARK: - Errors

enum ProxyError: LocalizedError {
    case notSignedIn
    case invalidResponse
    case serverError(status: Int, body: String)
    case noTextInResponse
    case blocked(reason: String)
    case payloadTooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Tracer — AI naming requires an account"
        case .invalidResponse:
            return "Invalid response from proxy"
        case .serverError(let status, let body):
            return "Proxy error (\(status)): \(body)"
        case .noTextInResponse:
            return "No text in Gemini response"
        case .blocked(let reason):
            return "Gemini blocked the response (\(reason))"
        case .payloadTooLarge(let bytes):
            return "Request body too large (\(bytes / 1024)KB) — not sent"
        }
    }

    /// Whether retrying the SAME request could plausibly succeed.
    ///
    /// Retrying a deterministic failure is pure waste: before this existed, a 413 cost six
    /// identical doomed POSTs (3 inner attempts × 2 outer passes) plus ~45s of backoff, and
    /// the caller could not tell it apart from a transient 503 because the retry loop only
    /// ever stringified the error.
    var isRetryable: Bool {
        switch self {
        case .payloadTooLarge, .notSignedIn:
            return false
        case .serverError(let status, _):
            // 4xx are deterministic: the request itself is wrong (too large, unauthorized,
            // malformed). 5xx and 429 are the genuinely transient ones — Gemini returns 503
            // "high demand" regularly and those retries do succeed.
            return !(status == 400 || status == 401 || status == 403 || status == 413)
        case .invalidResponse, .noTextInResponse, .blocked:
            // Model-side flakiness: a re-roll can legitimately produce a usable response.
            return true
        }
    }
}

/// Retryability for an arbitrary error. Non-`ProxyError` failures (URLSession timeouts,
/// connection drops, JSON serialization) are transient by nature, so they stay retryable.
func isRetryableError(_ error: Error) -> Bool {
    (error as? ProxyError)?.isRetryable ?? true
}
