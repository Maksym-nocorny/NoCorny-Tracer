import Foundation

/// Available video recording resolutions
enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case hd1080 = "1080p"
    case hd1440 = "1440p"
    case uhd4k = "4K"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .hd1080: return 1920
        case .hd1440: return 2560
        case .uhd4k: return 3840
        }
    }

    var height: Int {
        switch self {
        case .hd1080: return 1080
        case .hd1440: return 1440
        case .uhd4k: return 2160
        }
    }

    var displayName: String {
        switch self {
        case .hd1080: return "1920 × 1080"
        case .hd1440: return "2560 × 1440"
        case .uhd4k: return "3840 × 2160"
        }
    }
}

/// Available video recording frame rates
enum VideoFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue) fps"
    }
}
