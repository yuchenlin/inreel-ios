import Foundation
import Photos

enum LikedFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "liked.filter.all")
        case .photos: String(localized: "liked.filter.photos")
        case .videos: String(localized: "liked.filter.videos")
        }
    }

    func matches(_ asset: PHAsset) -> Bool {
        switch self {
        case .all:
            return asset.mediaType == .image || asset.mediaType == .video
        case .photos:
            return asset.mediaType == .image
        case .videos:
            return asset.mediaType == .video
        }
    }
}
