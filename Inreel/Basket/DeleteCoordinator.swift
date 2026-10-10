import Foundation
import Photos

/// Outcome of the basket "delete all" PhotoKit confirmation.
/// Cancel / Don't Allow must leave the pending-delete basket unchanged (no feed restore).
enum PhotoKitDeleteAllOutcome: Equatable {
    case confirmed
    case cancelledOrFailed
}

enum DeleteCoordinator {
    /// Moves assets to Recently Deleted via the system confirmation dialog.
    /// Throws (including user cancel) without mutating the caller's basket.
    static func deleteAssets(localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard !assets.isEmpty else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }
    }

    /// Maps a PhotoKit delete-all attempt into UI policy.
    /// - Confirmed → clear basket + scrub feed ghosts.
    /// - Cancelled / failed → **keep basket**, do **not** restore to feed
    ///   (single-item undo / X / 全部移出 still restore elsewhere).
    static func outcome(forDeleteAllResult success: Bool) -> PhotoKitDeleteAllOutcome {
        success ? .confirmed : .cancelledOrFailed
    }

    /// Whether feed-sequence restore should run for this delete-all outcome.
    /// Always `false` for cancel — basket stays pending-delete.
    static func shouldRestoreToFeed(after outcome: PhotoKitDeleteAllOutcome) -> Bool {
        switch outcome {
        case .confirmed: false
        case .cancelledOrFailed: false
        }
    }

    /// Whether pending basket rows should be removed for this outcome.
    static func shouldClearBasket(after outcome: PhotoKitDeleteAllOutcome) -> Bool {
        switch outcome {
        case .confirmed: true
        case .cancelledOrFailed: false
        }
    }
}
