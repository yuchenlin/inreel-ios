import Foundation
import Photos
import SwiftData

extension Notification.Name {
    /// Posted on main when a queued favorite write fails. `object` is the localIdentifier;
    /// `userInfo["isFavorite"]` is the restored (still persisted) value.
    static let inreelFavoriteWriteFailed = Notification.Name("inreel.favoriteWriteFailed")
}

/// Optimistic favorites: callers flip UI + haptics first, then enqueue here. PhotoKit writes run
/// in a detached task (main never waits), rapid toggles on one asset coalesce to the latest value,
/// and a confirmed like bumps Stats on a background SwiftData context. On failure the UI is told
/// to roll back and a light haptic fires.
@MainActor
final class FavoriteQueue {
    static let shared = FavoriteQueue()

    private struct Entry {
        var asset: PHAsset
        var desired: Bool
        var persisted: Bool
        var isWriting: Bool
    }

    private var entries: [String: Entry] = [:]

    private init() {}

    /// Value the UI should show while a write is queued or in flight; nil when PhotoKit is current.
    func pendingValue(for localIdentifier: String) -> Bool? {
        entries[localIdentifier]?.desired
    }

    /// `previous` is what the UI showed before this flip (the persisted value if nothing is pending).
    func setFavorite(_ value: Bool, for asset: PHAsset, previous: Bool, container: ModelContainer?) {
        let id = asset.localIdentifier
        if var entry = entries[id] {
            entry.desired = value
            entries[id] = entry
        } else {
            entries[id] = Entry(asset: asset, desired: value, persisted: previous, isWriting: false)
        }
        drain(id, container: container)
    }

    private func drain(_ id: String, container: ModelContainer?) {
        guard var entry = entries[id], !entry.isWriting else { return }
        guard entry.desired != entry.persisted else {
            entries[id] = nil
            return
        }
        entry.isWriting = true
        entries[id] = entry
        let target = entry.desired
        let asset = entry.asset

        Task { @MainActor in
            let succeeded = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try await PhotoLibrary.setFavorite(asset, isFavorite: target)
                    return true
                } catch {
                    return false
                }
            }.value

            guard var current = self.entries[id] else { return }
            current.isWriting = false
            if succeeded {
                current.persisted = target
                self.entries[id] = current
                if target, let container {
                    StatsStore.incrementLiked(container: container)
                }
                // A newer toggle may have landed while writing; write it or clear the entry.
                self.drain(id, container: container)
            } else {
                self.entries[id] = nil
                NotificationCenter.default.post(
                    name: .inreelFavoriteWriteFailed,
                    object: id,
                    userInfo: ["isFavorite": current.persisted]
                )
                Haptics.light()
            }
        }
    }
}
