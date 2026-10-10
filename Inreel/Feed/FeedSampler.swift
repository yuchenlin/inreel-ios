import Foundation
import Photos

/// Uniform / lightly stratified sampler. Session history stack max 50.
/// Fast seed for first card; background expand for large libraries (spec §10 / §12).
/// The pool is pre-shuffled and ordered local-first (see `AssetLocality.localFirstOrder`);
/// draws walk that order so `upcoming(limit:)` is exactly what the prefetcher should warm.
@Observable
@MainActor
final class FeedSampler {
    private(set) var identifiers: [String] = []
    private(set) var isReady = false
    private(set) var isEmpty = false
    private(set) var isExhausted = false
    private(set) var track: FeedTrack = .default
    private(set) var cooldownApplied = false
    /// Visible library size (for Limited banner).
    private(set) var visibleLibraryCount = 0
    private(set) var isExpanding = false

    private(set) var history: [String] = []
    private(set) var historyIndex: Int = -1

    private var sessionSeen = Set<String>()
    private var cooledIdentifiers = Set<String>()
    private var basketIdentifiers = Set<String>()
    /// Feed-sequence anchors recorded at basket time (prev/next neighbor ids).
    private var basketAnchors: [String: (previous: String?, next: String?)] = [:]
    private let maxHistory = 50
    /// Bumped on every rebuild so a stale background expand never overwrites a newer pool.
    @ObservationIgnored private var poolGeneration = 0
    /// Seed probes found no iCloud-only assets — skip probing the full pool.
    @ObservationIgnored private var libraryLooksLocal = false

    /// Soft cap after stratification for huge libraries.
    nonisolated private static let largeLibraryThreshold = 2_500
    nonisolated private static let stratifiedCap = 2_500
    nonisolated private static let seedSampleSize = 120
    /// Max time the seed may spend on locality probes before the first card shows.
    nonisolated private static let seedProbeBudget: Duration = .milliseconds(350)
    nonisolated private static let seedProbeConcurrency = 8
    nonisolated private static let expandProbeConcurrency = 4
    /// Minimum classified seed ids with zero cloud before assuming a fully local library.
    nonisolated private static let localLibraryEvidence = 48
    /// Upcoming ids kept in place when the pool is swapped (already being prefetched).
    nonisolated private static let preservedHeadCount = 12

    var currentIdentifier: String? {
        guard historyIndex >= 0, historyIndex < history.count else { return nil }
        return history[historyIndex]
    }

    var canGoBack: Bool {
        guard historyIndex > 0 else { return false }
        // Skip basketed entries still lingering in history.
        return history[..<historyIndex].contains { !basketIdentifiers.contains($0) }
    }

    /// Next card id without mutating history (for follow-finger peek / warm slot).
    func peekNextIdentifier() -> String? {
        if historyIndex >= 0, historyIndex < history.count - 1 {
            var idx = historyIndex + 1
            while idx < history.count {
                if !basketIdentifiers.contains(history[idx]) {
                    return history[idx]
                }
                idx += 1
            }
        }
        return identifiers.first(where: isDrawable)
    }

    /// Previous card id without mutating history (for follow-finger peek).
    func peekPrevIdentifier() -> String? {
        guard canGoBack else { return nil }
        var idx = historyIndex - 1
        while idx >= 0 {
            if !basketIdentifiers.contains(history[idx]) {
                return history[idx]
            }
            idx -= 1
        }
        return nil
    }

    func bootstrap(track: FeedTrack) async {
        await rebuild(track: track, clearHistory: true)
    }

    /// Rebuilds seed pool quickly. Call `expandInBackground` after first card.
    func rebuild(track: FeedTrack, clearHistory: Bool) async {
        poolGeneration += 1
        let generation = poolGeneration
        self.track = track
        isReady = false
        cooldownApplied = false
        isExhausted = false
        isExpanding = false
        if clearHistory {
            history = []
            historyIndex = -1
            sessionSeen = []
            cooledIdentifiers = []
        }

        let status = PhotoLibrary.currentAuthorizationStatus()
        guard status == .authorized || status == .limited else {
            identifiers = []
            visibleLibraryCount = 0
            isReady = true
            isEmpty = true
            return
        }

        let trackRaw = track.rawValue
        let seed = await Task.detached(priority: .userInitiated) { () -> (ids: [String], visible: Int, looksLocal: Bool) in
            let selected = FeedTrack.fromStorage(trackRaw)
            let visible = PhotoLibrary.visibleAssetCount()
            let sampled = Self.fetchSeedIdentifiers(track: selected, sampleSize: Self.seedSampleSize).shuffled()
            let locality = await AssetLocality.classify(
                sampled,
                maxConcurrent: Self.seedProbeConcurrency,
                timeBudget: Self.seedProbeBudget,
                qos: .userInitiated
            )
            let cloudCount = locality.values.reduce(0) { $0 + ($1 ? 0 : 1) }
            let looksLocal = cloudCount == 0 && locality.count >= Self.localLibraryEvidence
            return (AssetLocality.localFirstOrder(sampled, locality: locality), visible, looksLocal)
        }.value
        guard generation == poolGeneration else { return }

        visibleLibraryCount = seed.visible
        libraryLooksLocal = seed.looksLocal
        let pool = seed.ids.filter { !basketIdentifiers.contains($0) && !cooledIdentifiers.contains($0) }
        identifiers = clearHistory ? pool : preservingHead(in: pool)
        isReady = true
        refreshEmptyFlags()
    }

    /// Full / stratified scan; merges into the live pool without yanking the current card
    /// or the upcoming cards the prefetcher is already warming.
    func expandInBackground(track: FeedTrack) async {
        let generation = poolGeneration
        isExpanding = true
        defer {
            if generation == poolGeneration { isExpanding = false }
        }

        let trackRaw = track.rawValue
        let assumeLocal = libraryLooksLocal
        let job = Task.detached(priority: .utility) { () -> [String] in
            let selected = FeedTrack.fromStorage(trackRaw)
            let full = Self.fetchFullIdentifiers(track: selected).shuffled()
            guard !Task.isCancelled else { return [] }
            let locality = assumeLocal
                ? AssetLocality.cachedValues(for: full)
                : await AssetLocality.classify(full, maxConcurrent: Self.expandProbeConcurrency)
            return AssetLocality.localFirstOrder(full, locality: locality)
        }
        let expanded = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        guard !Task.isCancelled, generation == poolGeneration, !expanded.isEmpty else { return }

        let basket = basketIdentifiers
        let cooled = cooledIdentifiers
        var merged = expanded.filter { !basket.contains($0) && !cooled.contains($0) }

        // Seed ids outside a stratified sample stay drawable if they still exist.
        let mergedSet = Set(merged)
        let extras = identifiers.filter { !mergedSet.contains($0) }
        if !extras.isEmpty {
            let alive = PHAsset.fetchAssets(withLocalIdentifiers: extras, options: nil)
            var aliveIDs = Set<String>()
            alive.enumerateObjects { asset, _, _ in aliveIDs.insert(asset.localIdentifier) }
            merged.append(contentsOf: extras.filter { aliveIDs.contains($0) })
        }

        identifiers = preservingHead(in: merged)
        visibleLibraryCount = PhotoLibrary.visibleAssetCount()
        refreshEmptyFlags()
    }

    /// Next drawable ids in browse order (what `advance()` will return once history runs out).
    func upcoming(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(limit)
        for id in identifiers where isDrawable(id) {
            out.append(id)
            if out.count == limit { break }
        }
        return out
    }

    func applyCooldown(_ cooled: Set<String>) {
        cooledIdentifiers = cooled
        cooldownApplied = true
        if !cooled.isEmpty {
            identifiers = identifiers.filter { !cooled.contains($0) }
        }
        refreshEmptyFlags()
    }

    func applyBasketExclusion(_ basketed: Set<String>) {
        // Drop anchors for ids that left the basket outside restore (should be rare).
        for id in basketAnchors.keys where !basketed.contains(id) {
            basketAnchors.removeValue(forKey: id)
        }
        basketIdentifiers = basketed
        if !basketed.isEmpty {
            identifiers = identifiers.filter { !basketed.contains($0) }
            // Keep basketed ids in `history` as skipped ghosts so undo / basket-remove can
            // re-enter the exact prior sequence (same neighbors / order).
        }
        refreshEmptyFlags()
    }

    func noteCooled(_ id: String) {
        cooledIdentifiers.insert(id)
        refreshEmptyFlags()
    }

    func noteBasketed(
        _ id: String,
        previousNeighborID: String? = nil,
        nextNeighborID: String? = nil
    ) {
        basketIdentifiers.insert(id)
        basketAnchors[id] = (previousNeighborID, nextNeighborID)
        identifiers.removeAll { $0 == id }
        // Leave `id` in `history` as a skipped ghost. Navigation (`advance` / `goBack` /
        // peek) already ignores basketed entries; restore re-activates the same slot.
        refreshEmptyFlags()
    }

    /// Re-admit a pending-delete item into the feed sequence at its recorded place.
    /// - Returns `true` when `currentIdentifier` changed (caller should sync chrome/slots).
    @discardableResult
    func restoreBasketed(
        _ id: String,
        previousNeighborID: String? = nil,
        nextNeighborID: String? = nil,
        seekIfNear: Bool
    ) -> Bool {
        let recorded = basketAnchors.removeValue(forKey: id)
        let prev = previousNeighborID ?? recorded?.previous
        let next = nextNeighborID ?? recorded?.next
        basketIdentifiers.remove(id)

        let before = currentIdentifier
        let restoredIndex = ensureHistorySlot(
            for: id,
            previousNeighborID: prev,
            nextNeighborID: next
        )

        if seekIfNear, let restoredIndex, isNearRestoredIndex(restoredIndex) {
            historyIndex = restoredIndex
        }

        // Avoid drawing it again from the random pool while it lives in history.
        identifiers.removeAll { $0 == id }
        sessionSeen.insert(id)

        refreshEmptyFlags()
        return currentIdentifier != before
    }

    /// Restore several items (clear-all / PhotoKit cancel). Lands on the restored card
    /// immediately behind the current position when the user is still adjacent.
    @discardableResult
    func restoreBasketedMany(
        _ items: [(id: String, previousNeighborID: String?, nextNeighborID: String?)],
        seekIfNear: Bool
    ) -> Bool {
        guard !items.isEmpty else { return false }
        let before = currentIdentifier
        var restoredIndices: [Int] = []
        for item in items {
            let recorded = basketAnchors.removeValue(forKey: item.id)
            let prev = item.previousNeighborID ?? recorded?.previous
            let next = item.nextNeighborID ?? recorded?.next
            basketIdentifiers.remove(item.id)
            if let idx = ensureHistorySlot(
                for: item.id,
                previousNeighborID: prev,
                nextNeighborID: next
            ) {
                restoredIndices.append(idx)
            }
            identifiers.removeAll { $0 == item.id }
            sessionSeen.insert(item.id)
        }

        if seekIfNear, !restoredIndices.isEmpty {
            // Prefer the restored slot immediately before current (do not skip past the block).
            let current = historyIndex
            if let land = restoredIndices.filter({ $0 < current }).max(),
               isNearRestoredIndex(land) || restoredIndices.contains(where: { $0 == current - 1 }) {
                historyIndex = land
            } else if let land = restoredIndices.filter({ $0 <= current }).max(),
                      current >= 0,
                      isNearRestoredIndex(land) {
                historyIndex = land
            }
        }

        refreshEmptyFlags()
        return currentIdentifier != before
    }

    /// Permanent PhotoKit delete — drop ghosts from history / pool / anchors.
    func notePermanentlyDeleted(_ ids: [String]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        basketIdentifiers.subtract(doomed)
        for id in doomed {
            basketAnchors.removeValue(forKey: id)
        }
        identifiers.removeAll { doomed.contains($0) }

        guard history.contains(where: { doomed.contains($0) }) else {
            refreshEmptyFlags()
            return
        }
        var newHistory: [String] = []
        newHistory.reserveCapacity(history.count)
        var newIndex = historyIndex
        for (i, hid) in history.enumerated() {
            if doomed.contains(hid) {
                if i <= historyIndex {
                    newIndex -= 1
                }
                continue
            }
            newHistory.append(hid)
        }
        history = newHistory
        if history.isEmpty {
            historyIndex = -1
        } else if newIndex < 0 {
            historyIndex = 0
        } else {
            historyIndex = min(newIndex, history.count - 1)
        }
        refreshEmptyFlags()
    }

    /// Ensures `id` sits in `history` between its neighbors. Returns its index, or `nil`
    /// when it could only be admitted to the upcoming pool (no session anchors).
    private func ensureHistorySlot(
        for id: String,
        previousNeighborID: String?,
        nextNeighborID: String?
    ) -> Int? {
        if let existing = history.firstIndex(of: id) {
            return existing
        }

        let insertAt: Int?
        if let nextNeighborID, let nextIdx = history.firstIndex(of: nextNeighborID) {
            insertAt = nextIdx
        } else if let previousNeighborID, let prevIdx = history.firstIndex(of: previousNeighborID) {
            insertAt = prevIdx + 1
        } else {
            insertAt = nil
        }

        guard let insertAt else {
            // No live neighbors in this session — re-admit to the drawable pool.
            if !cooledIdentifiers.contains(id), !identifiers.contains(id) {
                identifiers.insert(id, at: 0)
            }
            return nil
        }

        let clamped = max(0, min(insertAt, history.count))
        history.insert(id, at: clamped)
        if clamped <= historyIndex {
            historyIndex += 1
        }
        if history.count > maxHistory {
            let overflow = history.count - maxHistory
            history.removeFirst(overflow)
            historyIndex = max(-1, historyIndex - overflow)
        }
        return history.firstIndex(of: id)
    }

    /// True when the user is still adjacent to the restored slot (typical undo-after-basket).
    private func isNearRestoredIndex(_ restoredIndex: Int) -> Bool {
        if historyIndex == restoredIndex { return true }
        if historyIndex == restoredIndex + 1 { return true }
        if historyIndex == restoredIndex - 1 { return true }
        return false
    }

    private func isDrawable(_ id: String) -> Bool {
        !sessionSeen.contains(id)
            && !cooledIdentifiers.contains(id)
            && !basketIdentifiers.contains(id)
    }

    /// Keeps the current upcoming head (still present in `pool`) at the front of the new order.
    private func preservingHead(in pool: [String]) -> [String] {
        let head = upcoming(limit: Self.preservedHeadCount)
        guard !head.isEmpty else { return pool }
        let poolSet = Set(pool)
        let keptHead = head.filter { poolSet.contains($0) }
        guard !keptHead.isEmpty else { return pool }
        let headSet = Set(keptHead)
        return keptHead + pool.filter { !headSet.contains($0) }
    }

    private func refreshEmptyFlags() {
        let hasAvailable = identifiers.contains(where: isDrawable)
        let libraryEmpty = identifiers.isEmpty && history.isEmpty
        isEmpty = libraryEmpty || (!hasAvailable && currentIdentifier == nil)
        isExhausted = !libraryEmpty && !hasAvailable
        if currentIdentifier != nil, !hasAvailable {
            isExhausted = true
            isEmpty = false
        }
    }

    @discardableResult
    func advance() -> String? {
        if historyIndex >= 0, historyIndex < history.count - 1 {
            var idx = historyIndex + 1
            while idx < history.count {
                if !basketIdentifiers.contains(history[idx]) {
                    historyIndex = idx
                    refreshEmptyFlags()
                    return currentIdentifier
                }
                idx += 1
            }
            // Remaining forward history is all basketed — fall through to sample.
        }

        guard let next = sampleNew() else {
            refreshEmptyFlags()
            return currentIdentifier
        }

        history.append(next)
        if history.count > maxHistory {
            let overflow = history.count - maxHistory
            history.removeFirst(overflow)
            historyIndex = history.count - 1
        } else {
            historyIndex = history.count - 1
        }
        refreshEmptyFlags()
        return next
    }

    @discardableResult
    func goBack() -> String? {
        guard canGoBack else { return currentIdentifier }
        var idx = historyIndex - 1
        while idx >= 0 {
            if !basketIdentifiers.contains(history[idx]) {
                historyIndex = idx
                refreshEmptyFlags()
                return currentIdentifier
            }
            idx -= 1
        }
        return currentIdentifier
    }

    /// Next id in the pre-shuffled, local-first order — no PhotoKit work on the main thread.
    private func sampleNew() -> String? {
        guard let pick = identifiers.first(where: isDrawable) else { return nil }
        sessionSeen.insert(pick)
        return pick
    }

    func asset(for identifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject
    }

#if DEBUG
    /// Test hook: install a synthetic session history without PhotoKit.
    func debugInstallSession(history: [String], historyIndex: Int, identifiers: [String] = []) {
        self.history = history
        self.historyIndex = historyIndex
        self.identifiers = identifiers
        self.sessionSeen = Set(history)
        self.isReady = true
        self.isEmpty = history.isEmpty && identifiers.isEmpty
        refreshEmptyFlags()
    }

    var debugHistory: [String] { history }
    var debugHistoryIndex: Int { historyIndex }
    var debugBasketIdentifiers: Set<String> { basketIdentifiers }
#endif

    // MARK: - Fetch

    /// Cheap random sample via PHFetchResult indexing (lazy).
    nonisolated private static func fetchSeedIdentifiers(track: FeedTrack, sampleSize: Int) -> [String] {
        let result = fetchResult(track: track)
        let count = result.count
        guard count > 0 else { return [] }

        let target = min(sampleSize, count)
        var indices = Set<Int>()
        indices.reserveCapacity(target)
        var attempts = 0
        while indices.count < target, attempts < target * 8 {
            indices.insert(Int.random(in: 0..<count))
            attempts += 1
        }

        var collected: [String] = []
        collected.reserveCapacity(indices.count)
        for idx in indices {
            let asset = result.object(at: idx)
            guard matches(track, asset: asset) else { continue }
            collected.append(asset.localIdentifier)
        }
        return collected
    }

    /// Full enumerate; year-bucket sample when huge (40% >2y / 40% 3–24mo / 20% recent).
    nonisolated private static func fetchFullIdentifiers(track: FeedTrack) -> [String] {
        let result = fetchResult(track: track)
        var dated: [(id: String, date: Date)] = []
        dated.reserveCapacity(min(result.count, stratifiedCap * 2))

        result.enumerateObjects { asset, _, _ in
            guard matches(track, asset: asset) else { return }
            dated.append((asset.localIdentifier, asset.creationDate ?? .distantPast))
        }

        guard dated.count > largeLibraryThreshold else {
            return dated.map(\.id)
        }
        return stratify(dated, cap: stratifiedCap)
    }

    nonisolated private static func stratify(
        _ dated: [(id: String, date: Date)],
        cap: Int
    ) -> [String] {
        let now = Date()
        let twoYears: TimeInterval = 365.25 * 24 * 3600 * 2
        let threeMonths: TimeInterval = 365.25 * 24 * 3600 * 0.25
        let twentyFourMonths: TimeInterval = 365.25 * 24 * 3600 * 2

        var older: [String] = []
        var mid: [String] = []
        var recent: [String] = []
        older.reserveCapacity(dated.count / 2)
        mid.reserveCapacity(dated.count / 3)
        recent.reserveCapacity(dated.count / 5)

        for item in dated {
            let age = now.timeIntervalSince(item.date)
            if age > twoYears {
                older.append(item.id)
            } else if age > threeMonths, age <= twentyFourMonths {
                // 3–24 months
                mid.append(item.id)
            } else {
                recent.append(item.id)
            }
        }

        let olderN = Int(Double(cap) * 0.40)
        let midN = Int(Double(cap) * 0.40)
        let recentN = cap - olderN - midN

        func sample(_ source: [String], _ n: Int) -> [String] {
            guard source.count > n else { return source }
            return Array(source.shuffled().prefix(n))
        }

        var out: [String] = []
        out.append(contentsOf: sample(older, olderN))
        out.append(contentsOf: sample(mid, midN))
        out.append(contentsOf: sample(recent, recentN))
        return out.shuffled()
    }

    nonisolated private static func fetchResult(track: FeedTrack) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        options.predicate = predicate(for: track)
        return PHAsset.fetchAssets(with: options)
    }

    nonisolated private static func predicate(for track: FeedTrack) -> NSPredicate {
        let image = PHAssetMediaType.image.rawValue
        let video = PHAssetMediaType.video.rawValue
        switch track {
        case .mixed, .screenshots:
            return NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                image,
                video
            )
        case .photos:
            return NSPredicate(format: "mediaType == %d", image)
        case .videos:
            return NSPredicate(format: "mediaType == %d", video)
        }
    }

    nonisolated private static func matches(_ track: FeedTrack, asset: PHAsset) -> Bool {
        if asset.isHidden { return false }
        if asset.sourceType.contains(.typeCloudShared) { return false }

        switch track {
        case .mixed:
            return asset.mediaType == .image || asset.mediaType == .video
        case .photos:
            return asset.mediaType == .image
                && !asset.mediaSubtypes.contains(.photoScreenshot)
        case .videos:
            return asset.mediaType == .video
        case .screenshots:
            return asset.mediaSubtypes.contains(.photoScreenshot)
                || asset.mediaSubtypes.contains(.videoScreenRecording)
        }
    }
}
