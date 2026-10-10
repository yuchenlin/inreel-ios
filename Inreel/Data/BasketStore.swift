import Foundation
import Photos
import SwiftData

extension Notification.Name {
    /// Posted when pending-delete items are restored to the feed (undo, basket X / clear all, PhotoKit cancel).
    /// `userInfo` keys: `ids` `[String]`, `previousNeighborIDs` `[String]` (empty = nil),
    /// `nextNeighborIDs` `[String]` (empty = nil). Parallel arrays, same order.
    static let inreelBasketDidRestore = Notification.Name("inreel.basketDidRestore")
    /// Posted after a successful PhotoKit move-to-Recently-Deleted so the feed can scrub ghosts.
    /// `userInfo["localIdentifiers"]` is `[String]`.
    static let inreelBasketDidPermanentlyDelete = Notification.Name("inreel.basketDidPermanentlyDelete")
}

@MainActor
final class BasketStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func allIdentifiers() throws -> Set<String> {
        let items = try context.fetch(FetchDescriptor<BasketItem>())
        return Set(items.map(\.localIdentifier))
    }

    func allItems() throws -> [BasketItem] {
        var descriptor = FetchDescriptor<BasketItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Feed-sequence anchors for a pending item (if still in the basket).
    func anchors(for localIdentifier: String) throws -> (previous: String?, next: String?)? {
        let id = localIdentifier
        let descriptor = FetchDescriptor<BasketItem>(
            predicate: #Predicate<BasketItem> { $0.localIdentifier == id }
        )
        guard let item = try context.fetch(descriptor).first else { return nil }
        return (item.previousNeighborID, item.nextNeighborID)
    }

    @discardableResult
    func add(
        asset: PHAsset,
        previousNeighborID: String? = nil,
        nextNeighborID: String? = nil
    ) throws -> BasketItem {
        let id = asset.localIdentifier
        let existing = FetchDescriptor<BasketItem>(
            predicate: #Predicate<BasketItem> { $0.localIdentifier == id }
        )
        if let found = try context.fetch(existing).first {
            // Keep the earliest feed anchors if already pending.
            if found.previousNeighborID == nil, found.nextNeighborID == nil {
                found.previousNeighborID = previousNeighborID
                found.nextNeighborID = nextNeighborID
                try context.save()
            }
            return found
        }
        let item = BasketItem(
            localIdentifier: id,
            cloudIdentifier: CloudIDMapper.cloudIdentifier(for: id),
            addedAt: .now,
            estimatedByteCount: Self.estimatedByteCount(for: asset),
            previousNeighborID: previousNeighborID,
            nextNeighborID: nextNeighborID
        )
        context.insert(item)
        try context.save()
        return item
    }

    func remove(localIdentifier: String) throws {
        let id = localIdentifier
        let descriptor = FetchDescriptor<BasketItem>(
            predicate: #Predicate<BasketItem> { $0.localIdentifier == id }
        )
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
        try context.save()
    }

    func remove(localIdentifiers: [String]) throws {
        let ids = Set(localIdentifiers)
        let items = try context.fetch(FetchDescriptor<BasketItem>())
        for item in items where ids.contains(item.localIdentifier) {
            context.delete(item)
        }
        try context.save()
    }

    /// Clears every pending basket row. Does **not** touch PhotoKit / Recently Deleted.
    func removeAll() throws {
        let items = try context.fetch(FetchDescriptor<BasketItem>())
        for item in items {
            context.delete(item)
        }
        try context.save()
    }

    struct RestorePayload: Equatable {
        var id: String
        var previousNeighborID: String?
        var nextNeighborID: String?
    }

    /// Snapshot restore payloads (id + neighbors) for the given rows, then delete them from SwiftData.
    func removeReturningRestorePayloads(localIdentifiers: [String]) throws -> [RestorePayload] {
        let ids = Set(localIdentifiers)
        let items = try context.fetch(FetchDescriptor<BasketItem>())
        var payloads: [RestorePayload] = []
        for item in items where ids.contains(item.localIdentifier) {
            payloads.append(
                RestorePayload(
                    id: item.localIdentifier,
                    previousNeighborID: item.previousNeighborID,
                    nextNeighborID: item.nextNeighborID
                )
            )
            context.delete(item)
        }
        try context.save()
        return payloads
    }

    /// Snapshot every pending row as restore payloads, then clear the basket.
    func removeAllReturningRestorePayloads() throws -> [RestorePayload] {
        let items = try context.fetch(FetchDescriptor<BasketItem>())
        let payloads = items.map {
            RestorePayload(
                id: $0.localIdentifier,
                previousNeighborID: $0.previousNeighborID,
                nextNeighborID: $0.nextNeighborID
            )
        }
        for item in items {
            context.delete(item)
        }
        try context.save()
        return payloads
    }

    static func postRestore(_ payloads: [RestorePayload]) {
        guard !payloads.isEmpty else { return }
        NotificationCenter.default.post(
            name: .inreelBasketDidRestore,
            object: nil,
            userInfo: [
                "ids": payloads.map(\.id),
                "previousNeighborIDs": payloads.map { $0.previousNeighborID ?? "" },
                "nextNeighborIDs": payloads.map { $0.nextNeighborID ?? "" }
            ]
        )
    }

    static func postPermanentDelete(localIdentifiers: [String]) {
        guard !localIdentifiers.isEmpty else { return }
        NotificationCenter.default.post(
            name: .inreelBasketDidPermanentlyDelete,
            object: nil,
            userInfo: ["localIdentifiers": localIdentifiers]
        )
    }

    /// Sum of known sizes; `nil` if every item lacks a size estimate.
    static func totalKnownBytes(in items: [BasketItem]) -> Int64? {
        let known = items.map(\.estimatedByteCount).filter { $0 > 0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }

    static func estimatedByteCount(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        var found = false
        for resource in resources {
            if let number = resource.value(forKey: "fileSize") as? NSNumber {
                total += number.int64Value
                found = true
            }
        }
        return found ? total : 0
    }

    static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
