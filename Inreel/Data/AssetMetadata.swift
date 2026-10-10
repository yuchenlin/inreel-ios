import Foundation
import Photos
import ImageIO
import CoreLocation
import AVFoundation

/// On-device capture metadata for feed chrome (time / place / camera).
/// Never uploads; reverse-geocode uses the system geocoder when online.
enum AssetMetadata {

    /// Relative capture age for feed chrome (e.g. "3 years ago" / "几年前").
    static func relativeDateText(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Locale-aware calendar date (EN medium e.g. "Mar 12, 2024"; ZH e.g. "2024年3月12日").
    static func exactDateText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Feed chrome date line: exact calendar when `exact` is true, else relative.
    static func dateText(from date: Date, exact: Bool) -> String {
        exact ? exactDateText(from: date) : relativeDateText(from: date)
    }

    /// Clock time of capture (localized short time).
    static func timeText(from date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Best-effort place name from `PHAsset.location`. Falls back to coordinates.
    static func locationText(for asset: PHAsset) async -> String? {
        guard let location = asset.location else { return nil }
        if let place = await reverseGeocode(location) {
            return place
        }
        return String(
            format: "%.2f°, %.2f°",
            locale: .current,
            location.coordinate.latitude,
            location.coordinate.longitude
        )
    }

    /// Camera make/model from ImageIO (photos) or AV metadata (videos).
    static func deviceText(for asset: PHAsset) async -> String? {
        if asset.mediaType == .video {
            return await videoDeviceText(for: asset)
        }
        return await imageDeviceText(for: asset)
    }

    // MARK: - Private

    private static func reverseGeocode(_ location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                guard let place = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let parts = [place.locality ?? place.subLocality, place.administrativeArea]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    continuation.resume(returning: parts.joined(separator: ", "))
                    return
                }
                if let name = place.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    continuation.resume(returning: name)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func imageDeviceText(for asset: PHAsset) async -> String? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .none
        options.version = .current

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return deviceText(fromImageData: data)
    }

    private static func deviceText(fromImageData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)
            ?? (exif?[kCGImagePropertyExifLensMake] as? String)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)
            ?? (exif?[kCGImagePropertyExifLensModel] as? String)
        return formatDevice(make: make, model: model)
    }

    private static func videoDeviceText(for asset: PHAsset) async -> String? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.version = .current

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
        guard let avAsset else { return nil }

        // Prefer common metadata model / make.
        var make: String?
        var model: String?
        for item in avAsset.commonMetadata {
            guard let key = item.commonKey else { continue }
            let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { continue }
            switch key {
            case .commonKeyMake: make = value
            case .commonKeyModel: model = value
            default: break
            }
        }
        if let formatted = formatDevice(make: make, model: model) {
            return formatted
        }

        // QuickTime / iTunes-style tags as fallback.
        for format in avAsset.availableMetadataFormats {
            for item in avAsset.metadata(forFormat: format) {
                let id = item.identifier?.rawValue.lowercased() ?? ""
                let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value, !value.isEmpty else { continue }
                if id.contains("model") { return value }
                if id.contains("make"), make == nil { make = value }
            }
        }
        return formatDevice(make: make, model: model)
    }

    private static func formatDevice(make: String?, model: String?) -> String? {
        let cleanMake = make?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanModel, !cleanModel.isEmpty {
            if let cleanMake,
               !cleanMake.isEmpty,
               cleanMake.lowercased() != "apple",
               !cleanModel.lowercased().contains(cleanMake.lowercased()) {
                return "\(cleanMake) \(cleanModel)"
            }
            return cleanModel
        }
        if let cleanMake, !cleanMake.isEmpty {
            return cleanMake
        }
        return nil
    }

    // MARK: - Albums

    /// User albums (and a few useful smart albums) that already contain this asset.
    static func albumNames(for asset: PHAsset) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        let userAlbums = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            appendAlbumTitle(collection.localizedTitle, into: &names, seen: &seen)
        }

        let smartAlbums = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .smartAlbum,
            options: nil
        )
        smartAlbums.enumerateObjects { collection, _, _ in
            guard isUsefulSmartAlbum(collection) else { return }
            appendAlbumTitle(collection.localizedTitle, into: &names, seen: &seen)
        }
        return names
    }

    /// Truncated album list for feed chrome, e.g. "Vacation, Family +2".
    static func albumText(for asset: PHAsset, maxVisible: Int = 2) -> String? {
        let names = albumNames(for: asset)
        guard !names.isEmpty else { return nil }
        if names.count <= maxVisible {
            return names.joined(separator: ", ")
        }
        let head = names.prefix(maxVisible).joined(separator: ", ")
        let rest = names.count - maxVisible
        return "\(head) +\(rest)"
    }

    private static func appendAlbumTitle(
        _ title: String?,
        into names: inout [String],
        seen: inout Set<String>
    ) {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        let key = raw.lowercased()
        guard !seen.contains(key) else { return }
        seen.insert(key)
        names.append(raw)
    }

    /// Skip noisy library-wide smart albums (Recents / Recently Added / Hidden).
    private static func isUsefulSmartAlbum(_ collection: PHAssetCollection) -> Bool {
        switch collection.assetCollectionSubtype {
        case .smartAlbumUserLibrary,
             .smartAlbumRecentlyAdded,
             .smartAlbumAllHidden,
             .smartAlbumGeneric:
            return false
        case .smartAlbumFavorites,
             .smartAlbumScreenshots,
             .smartAlbumSelfPortraits,
             .smartAlbumLivePhotos,
             .smartAlbumPanoramas,
             .smartAlbumBursts,
             .smartAlbumAnimated,
             .smartAlbumDepthEffect,
             .smartAlbumLongExposures,
             .smartAlbumVideos,
             .smartAlbumSlomoVideos,
             .smartAlbumTimelapses:
            return true
        default:
            return false
        }
    }
}
