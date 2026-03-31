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

    /// Sends a generateContent request to the Gemini proxy.
    /// - Parameters:
    ///   - model: Gemini model name (e.g. "gemini-2.0-flash")
    ///   - contents: Array of content objects matching Gemini API format
    /// - Returns: The generated text response
    func generateContent(model: String = "gemini-2.5-flash-lite", contents: [[String: Any]]) async throws -> String {
        let url = URL(string: "\(baseURL)/v1/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
        request.timeoutInterval = 120 // Gemini can be slow for large media

        let body: [String: Any] = ["contents": contents]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProxyError.serverError(status: httpResponse.statusCode, body: bodyStr)
        }

        // Parse Gemini response: { candidates: [{ content: { parts: [{ text: "..." }] } }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw ProxyError.noTextInResponse
        }

        return text
    }

    // MARK: - Convenience: Text + Images

    /// Generates content from a text prompt and optional inline image data.
    func generateWithImages(prompt: String, images: [Data], mimeType: String = "image/jpeg") async throws -> String {
        var parts: [[String: Any]] = [["text": prompt]]

        for imageData in images {
            parts.append([
                "inlineData": [
                    "mimeType": mimeType,
                    "data": imageData.base64EncodedString()
                ]
            ])
        }

        let contents: [[String: Any]] = [["parts": parts]]
        return try await generateContent(contents: contents)
    }

    /// Generates content from a text prompt and inline audio data.
    func generateWithAudio(prompt: String, audioData: Data, mimeType: String = "audio/mp4") async throws -> String {
        let parts: [[String: Any]] = [
            ["text": prompt],
            [
                "inlineData": [
                    "mimeType": mimeType,
                    "data": audioData.base64EncodedString()
                ]
            ]
        ]

        let contents: [[String: Any]] = [["parts": parts]]
        return try await generateContent(contents: contents)
    }
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
