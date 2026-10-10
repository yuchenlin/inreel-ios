import Foundation
import Photos
import PhotosUI
import UIKit

extension Notification.Name {
    /// Posted after a successful local favorite toggle so Liked tab can refresh even if PhotoKit change observer is missed (Simulator).
    static let inreelFavoritesDidChange = Notification.Name("inreel.favoritesDidChange")
}

enum PhotoLibrary {
    static func currentAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Approximate count of assets visible under current authorization (limited = selected only).
    static func visibleAssetCount() -> Int {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        return PHAsset.fetchAssets(with: options).count
    }

    /// Present the system limited-library picker from the key window’s root VC.
    @MainActor
    static func presentLimitedLibraryPicker() {
        guard let root = topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// PhotoKit write only — call from a background task (see `FavoriteQueue`); UI flips first.
    static func setFavorite(_ asset: PHAsset, isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = isFavorite
        }
        let id = asset.localIdentifier
        await MainActor.run {
            NotificationCenter.default.post(name: .inreelFavoritesDidChange, object: id)
        }
    }

    /// System Favorites smart album first (more reliable on Simulator than `isFavorite` predicate).
    static func fetchFavorites() -> [PHAsset] {
        let sort = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        options.sortDescriptors = sort

        if let collection = favoritesSmartAlbum() {
            let result = PHAsset.fetchAssets(in: collection, options: options)
            let fromAlbum = collectVisible(from: result)
            if !fromAlbum.isEmpty {
                return fromAlbum
            }
            // Empty album can still be correct; also try predicate in case Simulator album lags.
        }

        return fetchFavoritesViaPredicate(sort: sort)
    }

    private static func favoritesSmartAlbum() -> PHAssetCollection? {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumFavorites,
            options: nil
        )
        return albums.firstObject
    }

    private static func fetchFavoritesViaPredicate(sort: [NSSortDescriptor]) -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        options.predicate = NSPredicate(format: "isFavorite == YES")
        options.sortDescriptors = sort
        let result = PHAsset.fetchAssets(with: options)
        return collectVisible(from: result)
    }

    private static func collectVisible(from result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.isHidden { return }
            if asset.sourceType.contains(.typeCloudShared) { return }
            assets.append(asset)
        }
        return assets
    }
}
