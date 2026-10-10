import Foundation
import Photos
import Observation
import SwiftData

@Observable
@MainActor
final class FeedViewModel {
    let sampler = FeedSampler()
    var currentAsset: PHAsset?
    var showChrome = true
    var isLoading = true
    var loadFailed = false
    var track: FeedTrack = .default
    var limitedAssetCount: Int = 0

    private var seenStore: SeenStore?
    private var basketStore: BasketStore?
    private var modelContext: ModelContext?
    private var cooldownDays: Int = AppSettings.defaultCooldownDays
    private var lastMarkedID: String?
    private var libraryObserver: FeedLibraryObserver?
    private var expandTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var basketRestoreObserver: NSObjectProtocol?
    private var basketDeleteObserver: NSObjectProtocol?
    /// Coalesces PhotoKit change bursts (favorites, iCloud downloads, Limited picker edits).
    private static let libraryChangeDebounce: UInt64 = 700_000_000

    func configure(modelContext: ModelContext, cooldownDays: Int) {
        self.modelContext = modelContext
        self.seenStore = SeenStore(context: modelContext)
        self.basketStore = BasketStore(context: modelContext)
        self.cooldownDays = cooldownDays
        startObservingLibrary()
        startObservingBasketRestores()
    }

    func updateCooldownDays(_ days: Int) {
        cooldownDays = days
    }

    func start(track: FeedTrack) async {
        self.track = track
        isLoading = true
        lastMarkedID = nil

        // Fast seed → first card ASAP (spec §10 / §12).
        await sampler.rebuild(track: track, clearHistory: true)
        applyBasketFromStore()
        applyCooldownFromStore()
        _ = sampler.advance()
        syncCurrent(markSeen: true)
        limitedAssetCount = sampler.visibleLibraryCount
        isLoading = false
        updatePrefetch()

        expandTask?.cancel()
        expandTask = Task { @MainActor in
            await self.sampler.expandInBackground(track: track)
            guard !Task.isCancelled else { return }
            self.applyBasketFromStore()
            self.applyCooldownFromStore()
            self.limitedAssetCount = self.sampler.visibleLibraryCount
            self.updatePrefetch()
            self.seenStore?.repairLocalIdentifiers()
        }
    }

    func setTrack(_ newTrack: FeedTrack) async {
        guard newTrack != track else { return }
        track = newTrack
        isLoading = true
        currentAsset = nil
        lastMarkedID = nil
        expandTask?.cancel()

        await sampler.rebuild(track: newTrack, clearHistory: true)
        applyBasketFromStore()
        applyCooldownFromStore()
        _ = sampler.advance()
        syncCurrent(markSeen: true)
        limitedAssetCount = sampler.visibleLibraryCount
        isLoading = false
        Haptics.selection()
        updatePrefetch()

        expandTask = Task { @MainActor in
            await self.sampler.expandInBackground(track: newTrack)
            guard !Task.isCancelled else { return }
            self.applyBasketFromStore()
            self.applyCooldownFromStore()
            self.limitedAssetCount = self.sampler.visibleLibraryCount
            self.updatePrefetch()
        }
    }

    /// Limited picker / library edits — refresh pool, keep session history when possible.
    /// A live pool is re-expanded in place (upcoming head preserved, so prefetch stays warm);
    /// only an empty pool pays for a fresh seed.
    func handleLibraryChange() async {
        limitedAssetCount = PhotoLibrary.visibleAssetCount()
        expandTask?.cancel()
        if sampler.currentIdentifier == nil || sampler.identifiers.isEmpty {
            await sampler.rebuild(track: track, clearHistory: false)
            applyBasketFromStore()
            applyCooldownFromStore()
            if sampler.currentIdentifier == nil {
                _ = sampler.advance()
                syncCurrent(markSeen: true)
            } else {
                syncCurrent(markSeen: false)
            }
            updatePrefetch()
        }

        expandTask = Task { @MainActor in
            await self.sampler.expandInBackground(track: self.track)
            guard !Task.isCancelled else { return }
            self.applyBasketFromStore()
            self.applyCooldownFromStore()
            self.limitedAssetCount = self.sampler.visibleLibraryCount
            if self.sampler.currentIdentifier == nil {
                _ = self.sampler.advance()
                self.syncCurrent(markSeen: true)
            } else {
                self.syncCurrent(markSeen: false)
            }
            self.updatePrefetch()
        }
    }

    private func scheduleLibraryChange() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.libraryChangeDebounce)
            guard !Task.isCancelled else { return }
            await self.handleLibraryChange()
        }
    }

    func next() {
        _ = sampler.advance()
        syncCurrent(markSeen: true)
        Haptics.selection()
        updatePrefetch()
    }

    func previous() {
        guard sampler.canGoBack else { return }
        _ = sampler.goBack()
        syncCurrent(markSeen: true)
        Haptics.selection()
        updatePrefetch()
    }

    func peekNextAsset() -> PHAsset? {
        guard let id = sampler.peekNextIdentifier() else { return nil }
        return sampler.asset(for: id)
    }

    func peekPrevAsset() -> PHAsset? {
        guard let id = sampler.peekPrevIdentifier() else { return nil }
        return sampler.asset(for: id)
    }

    func sendCurrentToBasket() {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        // Capture neighbors before advance so restore can re-thread the exact sequence.
        let previousNeighborID = sampler.peekPrevIdentifier()
        let nextNeighborID = sampler.peekNextIdentifier()
        do {
            _ = try basketStore?.add(
                asset: asset,
                previousNeighborID: previousNeighborID,
                nextNeighborID: nextNeighborID
            )
        } catch {
            Haptics.light()
            return
        }
        // Marks pending-delete + keeps a history ghost; Basket tab owns until PhotoKit delete.
        sampler.noteBasketed(
            id,
            previousNeighborID: previousNeighborID,
            nextNeighborID: nextNeighborID
        )
        Haptics.basket()
        _ = sampler.advance()
        syncCurrent(markSeen: true)
        updatePrefetch()
    }

    /// Undo a just-basketed item: SwiftData remove + restore exact feed-sequence slot.
    /// If the user is still on the next neighbor, land on the restored card (do not skip past).
    func undoBasket(localIdentifier id: String) {
        var previousNeighborID: String?
        var nextNeighborID: String?
        if let store = basketStore, let anchors = try? store.anchors(for: id) {
            previousNeighborID = anchors.previous
            nextNeighborID = anchors.next
        }
        do {
            try basketStore?.remove(localIdentifier: id)
        } catch {
            Haptics.warning()
            return
        }
        let landed = sampler.restoreBasketed(
            id,
            previousNeighborID: previousNeighborID,
            nextNeighborID: nextNeighborID,
            seekIfNear: true
        )
        Haptics.light()
        if landed {
            syncCurrent(markSeen: true)
        }
        updatePrefetch()
    }

    /// Basket tab X / clear-all / PhotoKit cancel — restore each item to its prior feed slot.
    func handleBasketRestore(items: [(id: String, previousNeighborID: String?, nextNeighborID: String?)]) {
        guard !items.isEmpty else { return }
        let landed = sampler.restoreBasketedMany(items, seekIfNear: true)
        if landed {
            syncCurrent(markSeen: true)
        }
        updatePrefetch()
    }

    func handleBasketPermanentDelete(localIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        sampler.notePermanentlyDeleted(ids)
        syncCurrent(markSeen: false)
        updatePrefetch()
    }

    private func applyCooldownFromStore() {
        guard let seenStore else { return }
        let cooled: Set<String>
        do {
            cooled = try seenStore.activeCooldownIdentifiers()
        } catch {
            return
        }
        sampler.applyCooldown(cooled)
    }

    private func applyBasketFromStore() {
        guard let basketStore else { return }
        let basketed: Set<String>
        do {
            basketed = try basketStore.allIdentifiers()
        } catch {
            return
        }
        sampler.applyBasketExclusion(basketed)
    }

    private func syncCurrent(markSeen: Bool) {
        if let id = sampler.currentIdentifier {
            currentAsset = sampler.asset(for: id)
            loadFailed = currentAsset == nil
            if markSeen {
                persistSeen(id)
            }
        } else {
            currentAsset = nil
            loadFailed = false
        }
    }

    private func persistSeen(_ id: String) {
        guard lastMarkedID != id else { return }
        lastMarkedID = id
        seenStore?.markSeen(localIdentifier: id, cooldownDays: cooldownDays)
        sampler.noteCooled(id)
    }

    private func updatePrefetch() {
        FeedImagePrefetcher.shared.updateWindow(
            centerIdentifier: sampler.currentIdentifier,
            history: sampler.history,
            upcoming: sampler.upcoming(limit: FeedImagePrefetcher.lookahead)
        )
    }

    private func startObservingLibrary() {
        guard libraryObserver == nil else { return }
        let observer = FeedLibraryObserver { [weak self] in
            Task { @MainActor in
                self?.scheduleLibraryChange()
            }
        }
        libraryObserver = observer
        PHPhotoLibrary.shared().register(observer)
    }

    private func startObservingBasketRestores() {
        if basketRestoreObserver == nil {
            basketRestoreObserver = NotificationCenter.default.addObserver(
                forName: .inreelBasketDidRestore,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let ids = note.userInfo?["ids"] as? [String] ?? []
                let prevs = note.userInfo?["previousNeighborIDs"] as? [String] ?? []
                let nexts = note.userInfo?["nextNeighborIDs"] as? [String] ?? []
                var items: [(id: String, previousNeighborID: String?, nextNeighborID: String?)] = []
                items.reserveCapacity(ids.count)
                for (i, id) in ids.enumerated() {
                    let prev = i < prevs.count && !prevs[i].isEmpty ? prevs[i] : nil
                    let next = i < nexts.count && !nexts[i].isEmpty ? nexts[i] : nil
                    items.append((id, prev, next))
                }
                Task { @MainActor in
                    self?.handleBasketRestore(items: items)
                }
            }
        }
        if basketDeleteObserver == nil {
            basketDeleteObserver = NotificationCenter.default.addObserver(
                forName: .inreelBasketDidPermanentlyDelete,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let ids = note.userInfo?["localIdentifiers"] as? [String] ?? []
                Task { @MainActor in
                    self?.handleBasketPermanentDelete(localIdentifiers: ids)
                }
            }
        }
    }
}

private final class FeedLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
