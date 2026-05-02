import Foundation

/// HTTP client that proxies Gemini API calls through the Cloudflare Worker.
/// The real Gemini API key lives only on the Worker — the app never sees it.
final class GeminiProxyClient {
    private let baseURL: String
    private let appSecret: String

    init(baseURL: String = AppSecrets.proxyBaseURL, appSecret: String = AppSecrets.appSecret) {
        self.baseURL = baseURL
        self.appSecret = appSecret
    }

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
        let url = URL(string: "\(baseURL)/v1/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
        request.timeoutInterval = 120 // Gemini can be slow for large media

        var body: [String: Any] = [
            "contents": contents,
            "safetySettings": Self.defaultSafetySettings,
        ]
        if let cfg = generationConfig {
            body["generationConfig"] = cfg
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
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
    case invalidResponse
    case serverError(status: Int, body: String)
    case noTextInResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from proxy"
        case .serverError(let status, let body):
            return "Proxy error (\(status)): \(body)"
        case .noTextInResponse:
            return "No text in Gemini response"
        }
    }
}
