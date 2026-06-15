import Foundation

/// Tri-state result for network calls so callers can distinguish an authoritative
/// server "no" from a transient failure.
///
/// The whole point of this type: a transient failure (offline, timeout, 5xx,
/// unparseable response) must NEVER be treated as an authoritative negative.
/// Conflating the two is what let a single Wi-Fi blip wipe the entire local
/// recordings library (`syncDropboxFromTracer` → `resetTracerLibraryState`).
enum APIResult<Success> {
    /// HTTP 200 and the body decoded into a usable payload.
    case success(Success)

    /// The server was reachable and gave a *definitive* negative answer —
    /// HTTP 401/403/404, or an in-band `{connected:false}`. Safe to act on
    /// authoritatively (e.g. clear local state).
    case authoritativeNegative

    /// We could not obtain an answer we can trust: offline, timeout, DNS failure,
    /// HTTP 5xx/429, or a 200 whose body failed to decode. Callers MUST preserve
    /// existing state and treat this as "unknown — retry later".
    case transientFailure

    /// The success payload, if any. `nil` for both negative cases.
    var value: Success? {
        if case .success(let v) = self { return v }
        return nil
    }
}

/// Short-lived Dropbox access token issued by the Tracer backend, with its parsed
/// expiry. Returned as the success payload of `fetchDropboxAccessToken()`.
struct DropboxTokenResult {
    let token: String
    let expiresAt: Date?
}
