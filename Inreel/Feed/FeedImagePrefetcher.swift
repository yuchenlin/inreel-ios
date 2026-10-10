import AVFoundation
import Foundation
import Photos
import UIKit

/// Two-lane prefetch along the feed's real browse order (forward history + sampler upcoming).
/// Near lane (next few cards + previous couple): aggressive HQ image / player-item requests that
/// hold a worker slot until HQ lands, with decoded frames kept in an LRU so the next swipe paints
/// from memory. Far lane (further ahead): silent network-allowed HQ requests that pull iCloud
/// bytes into Photos' local store without touching UI. Both lanes are capped and cancel work
/// that falls out of the window (including the cheap preview requests). On a memory warning the
/// decoded LRU is trimmed to the near window and the far lane is cancelled. AVPlayer playback
/// is capped at 2 in `VideoPlayerPool` (current + peek).
@MainActor
final class FeedImagePrefetcher {
    static let shared = FeedImagePrefetcher()

    let manager = PHCachingImageManager()

    /// Upcoming ids the feed should pass in (near ahead + far ahead).
    static let lookahead = 16

    /// Next cards warmed aggressively (decoded HQ in memory).
    private let nearAhead = 4
    /// Previous cards kept warm for a quick swipe back.
    private let nearBehind = 2
    private let maxNearWorkers = 4
    /// Far lane is download-only and deliberately narrow (battery / data).
    private let maxFarWorkers = 2
    /// Soft cap on PHCaching IDs (active window + sticky retention of recent neighbors).
    private let maxStickyCache = 28
    private let maxDecodedImages = 28
    /// Ids known to paint without network this session (bounded).
    private let maxWarmRemembered = 600

    private struct Inflight {
        let requestID: PHImageRequestID
        let token: Int
    }

    private struct DecodedFrame {
        let image: UIImage
        let isHighQuality: Bool
    }

    private var nearIDs: [String] = []
    private var farIDs: [String] = []
    private var cachedIDs: [String] = []
    private var nearRequests: [String: Inflight] = [:]
    private var farRequests: [String: Inflight] = [:]
    private var nextToken = 0
    /// Window-scoped: near failures / finished far work are not retried until they leave the window.
    private var nearFailedIDs: Set<String> = []
    private var farSettledIDs: Set<String> = []
    private var previewRequestedIDs: Set<String> = []
    /// In-flight opportunistic preview requests — cancelled when they leave the window.
    private var previewRequests: [String: PHImageRequestID] = [:]
    private var memoryObserver: NSObjectProtocol?

    private var warmIDs: Set<String> = []
    private var warmOrder: [String] = []

    /// Decoded frames / posters for immediate paint while HQ / iCloud catches up.
    private var decodedByID: [String: DecodedFrame] = [:]
    /// Least-recently-used at index 0.
    private var decodedLRU: [String] = []

    private let targetSize: CGSize = {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }()

    private init() {
        manager.allowsCachingHighQualityImages = true
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FeedImagePrefetcher.shared.handleMemoryWarning()
            }
        }
    }

    /// Memory pressure: keep decoded frames only for the near window (what the next swipe
    /// paints), cancel the far lane (pure iCloud warming) — it refills on the next window update.
    func handleMemoryWarning() {
        let keep = Set(nearIDs)
        decodedLRU.removeAll { !keep.contains($0) }
        decodedByID = decodedByID.filter { keep.contains($0.key) }
        for (_, inflight) in farRequests {
            manager.cancelImageRequest(inflight.requestID)
        }
        farRequests.removeAll()
        farSettledIDs.removeAll()
    }

    // MARK: - Decoded frame cache (placeholder / last frame)

    func cachedImage(for localIdentifier: String) -> UIImage? {
        cachedFrame(for: localIdentifier)?.image
    }

    func cachedFrame(for localIdentifier: String) -> (image: UIImage, isHighQuality: Bool)? {
        guard let frame = decodedByID[localIdentifier] else { return nil }
        touchDecoded(localIdentifier)
        return (frame.image, frame.isHighQuality)
    }

    /// Never downgrades a cached HQ frame to a degraded one.
    func storeImage(_ image: UIImage, for localIdentifier: String, isHighQuality: Bool) {
        if !isHighQuality, decodedByID[localIdentifier]?.isHighQuality == true {
            touchDecoded(localIdentifier)
            return
        }
        decodedByID[localIdentifier] = DecodedFrame(image: image, isHighQuality: isHighQuality)
        touchDecoded(localIdentifier)
        trimDecoded()
    }

    private func touchDecoded(_ id: String) {
        decodedLRU.removeAll { $0 == id }
        decodedLRU.append(id)
    }

    private func trimDecoded() {
        while decodedLRU.count > maxDecodedImages, let oldest = decodedLRU.first {
            decodedLRU.removeFirst()
            decodedByID.removeValue(forKey: oldest)
        }
    }

    // MARK: - Warm state (drives download chrome)

    /// True when this asset should paint without network: HQ already delivered this session,
    /// HQ frame in memory, or its primary resource is on device.
    func isWarm(_ localIdentifier: String) -> Bool {
        warmIDs.contains(localIdentifier)
            || decodedByID[localIdentifier]?.isHighQuality == true
            || AssetLocality.cachedIsLocal(localIdentifier) == true
    }

    /// Cards call this once HQ / a playable item is on screen.
    func noteWarm(_ localIdentifier: String) {
        guard warmIDs.insert(localIdentifier).inserted else { return }
        warmOrder.append(localIdentifier)
        if warmOrder.count > maxWarmRemembered {
            let overflow = warmOrder.count - maxWarmRemembered
            for id in warmOrder.prefix(overflow) { warmIDs.remove(id) }
            warmOrder.removeFirst(overflow)
        }
    }

    // MARK: - Window

    /// `upcoming` is the sampler's next draws after history runs out (`FeedSampler.upcoming`).
    func updateWindow(centerIdentifier: String?, history: [String], upcoming: [String]) {
        var ahead: [String] = []
        var behind: [String] = []
        if let center = centerIdentifier, let idx = history.firstIndex(of: center) {
            ahead.append(contentsOf: history[(idx + 1)...])
            behind = Array(history[..<idx].reversed().prefix(nearBehind))
        }
        ahead.append(contentsOf: upcoming)

        var seen: Set<String> = []
        if let center = centerIdentifier { seen.insert(center) }
        ahead = ahead.filter { seen.insert($0).inserted }
        behind = behind.filter { seen.insert($0).inserted }

        // Priority: next cards first, then previous, then center (the card loads it itself).
        var near = Array(ahead.prefix(nearAhead)) + behind
        if let center = centerIdentifier { near.append(center) }
        let far = Array(ahead.dropFirst(nearAhead).prefix(max(0, Self.lookahead - nearAhead)))

        nearIDs = near
        farIDs = far
        let window = Set(near).union(far)
        nearFailedIDs.formIntersection(window)
        farSettledIDs.formIntersection(window)
        previewRequestedIDs.formIntersection(window)
        cancelStaleRequests(keeping: window)

        // Sticky PHCaching: keep recently adjacent IDs longer; only stop when they fall out of the ring.
        var sticky = near + far
        for id in cachedIDs where !window.contains(id) {
            sticky.append(id)
        }
        if sticky.count > maxStickyCache {
            sticky = Array(sticky.prefix(maxStickyCache))
        }
        reconcileCaching(desired: sticky)

        fillWorkers()
    }

    func stopAll() {
        cancelStaleRequests(keeping: [])
        stopCaching(cachedIDs)
        cachedIDs = []
        nearIDs = []
        farIDs = []
        nearFailedIDs = []
        farSettledIDs = []
        previewRequestedIDs = []
        decodedByID.removeAll()
        decodedLRU.removeAll()
    }

    // MARK: - Caching window

    private func reconcileCaching(desired: [String]) {
        let desiredSet = Set(desired)
        let currentSet = Set(cachedIDs)
        let toStop = cachedIDs.filter { !desiredSet.contains($0) }
        let toStart = desired.filter { !currentSet.contains($0) }
        if !toStop.isEmpty { stopCaching(toStop) }
        if !toStart.isEmpty { startCaching(toStart) }
        cachedIDs = desired
    }

    private func startCaching(_ ids: [String]) {
        let assets = assets(for: ids)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: cachingOptions()
        )
    }

    private func stopCaching(_ ids: [String]) {
        let assets = assets(for: ids)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: cachingOptions()
        )
    }

    // MARK: - Workers

    private func fillWorkers() {
        fillNear()
        fillFar()
    }

    private func fillNear() {
        var slots = maxNearWorkers - nearRequests.count
        guard slots > 0 else { return }
        let candidates = nearIDs.filter {
            nearRequests[$0] == nil && farRequests[$0] == nil && !nearFailedIDs.contains($0)
        }
        guard !candidates.isEmpty else { return }
        for asset in assets(for: candidates) where slots > 0 {
            let id = asset.localIdentifier
            if asset.mediaType == .video {
                requestPreviewFrameIfNeeded(asset)
                guard !warmIDs.contains(id) else { continue }
                startNearVideo(asset)
            } else {
                guard decodedByID[id]?.isHighQuality != true else { continue }
                requestPreviewFrameIfNeeded(asset)
                startNearImage(asset)
            }
            slots -= 1
        }
    }

    private func fillFar() {
        var slots = maxFarWorkers - farRequests.count
        guard slots > 0 else { return }
        let candidates = farIDs.filter {
            farRequests[$0] == nil
                && nearRequests[$0] == nil
                && !farSettledIDs.contains($0)
                && !isWarm($0)
        }
        guard !candidates.isEmpty else { return }
        for asset in assets(for: candidates) where slots > 0 {
            startFarDownload(asset)
            slots -= 1
        }
    }

    private func makeToken() -> Int {
        nextToken += 1
        return nextToken
    }

    /// Cheap opportunistic frame into the decoded LRU so a swipe can paint while HQ pulls (no slot).
    private func requestPreviewFrameIfNeeded(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard decodedByID[id] == nil, previewRequestedIDs.insert(id).inserted else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let req = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            // Opportunistic: a degraded frame may precede the final one; the final (or a
            // cancel / error) ends the request.
            let finished = cancelled || failed || !degraded
            Task { @MainActor in
                guard let self else { return }
                if finished { self.previewRequests.removeValue(forKey: id) }
                guard !cancelled, let image else { return }
                self.storeImage(image, for: id, isHighQuality: !degraded)
            }
        }
        previewRequests[id] = req
    }

    /// Near image: hold the slot until the non-degraded (HQ) frame lands in the decoded LRU.
    private func startNearImage(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let token = makeToken()
        let req = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: highQualityOptions()
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            if degraded && !cancelled { return }
            Task { @MainActor in
                guard let self, self.nearRequests[id]?.token == token else { return }
                self.nearRequests.removeValue(forKey: id)
                if let image, !failed {
                    self.storeImage(image, for: id, isHighQuality: true)
                    self.noteWarm(id)
                    AssetLocality.markLocal(id)
                } else if !cancelled {
                    self.nearFailedIDs.insert(id)
                }
                self.fillWorkers()
            }
        }
        nearRequests[id] = Inflight(requestID: req, token: token)
    }

    /// Near video: warm the player item bytes (dropped afterwards; playback pool stays ≤2).
    private func startNearVideo(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let token = makeToken()
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { _, error, stop, _ in
            if error != nil { stop.pointee = true }
        }
        let req = manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let ok = item != nil && info?[PHImageErrorKey] == nil
            Task { @MainActor in
                guard let self, self.nearRequests[id]?.token == token else { return }
                self.nearRequests.removeValue(forKey: id)
                if ok {
                    self.noteWarm(id)
                } else if !cancelled {
                    self.nearFailedIDs.insert(id)
                }
                self.fillWorkers()
            }
        }
        nearRequests[id] = Inflight(requestID: req, token: token)
    }

    /// Far lane: network-allowed HQ request purely to land iCloud bytes in Photos' local store.
    /// Videos only warm their HQ poster here; the player item waits for the near lane.
    private func startFarDownload(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let isVideo = asset.mediaType == .video
        let token = makeToken()
        let req = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: highQualityOptions()
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            if degraded && !cancelled { return }
            Task { @MainActor in
                guard let self, self.farRequests[id]?.token == token else { return }
                self.farRequests.removeValue(forKey: id)
                self.farSettledIDs.insert(id)
                if let image, !failed {
                    if !isVideo {
                        self.noteWarm(id)
                        AssetLocality.markLocal(id)
                    }
                    // Promoted into the near window while downloading — keep the frame.
                    if self.nearIDs.contains(id) {
                        self.storeImage(image, for: id, isHighQuality: true)
                    }
                }
                self.fillWorkers()
            }
        }
        farRequests[id] = Inflight(requestID: req, token: token)
    }

    private func cancelStaleRequests(keeping: Set<String>) {
        for (id, requestID) in previewRequests where !keeping.contains(id) {
            manager.cancelImageRequest(requestID)
            previewRequests.removeValue(forKey: id)
        }
        for (id, inflight) in nearRequests where !keeping.contains(id) {
            manager.cancelImageRequest(inflight.requestID)
            nearRequests.removeValue(forKey: id)
        }
        for (id, inflight) in farRequests where !keeping.contains(id) {
            manager.cancelImageRequest(inflight.requestID)
            farRequests.removeValue(forKey: id)
        }
    }

    // MARK: - Helpers

    private func assets(for ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        let map = Dictionary(uniqueKeysWithValues: list.map { ($0.localIdentifier, $0) })
        return ids.compactMap { map[$0] }
    }

    private func highQualityOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.progressHandler = { _, error, stop, _ in
            if error != nil { stop.pointee = true }
        }
        return options
    }

    private func cachingOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }
}
