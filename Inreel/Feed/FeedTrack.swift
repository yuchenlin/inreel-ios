import Foundation

/// Feed track filters (spec §2.1 / §5.6). Persisted as AppStorage `feedFilter`.
enum FeedTrack: String, CaseIterable, Identifiable, Sendable {
    case mixed
    case photos
    case videos
    case screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixed: String(localized: "track.mixed")
        case .photos: String(localized: "track.photos")
        case .videos: String(localized: "track.videos")
        case .screenshots: String(localized: "track.screenshots")
        }
    }

    /// Spec AppStorage key (migrated from legacy `feedTrack`).
    static let storageKey = AppSettings.feedFilterKey
    static let `default`: FeedTrack = .mixed

    static func fromStorage(_ raw: String) -> FeedTrack {
        FeedTrack(rawValue: raw) ?? .default
    }
}
