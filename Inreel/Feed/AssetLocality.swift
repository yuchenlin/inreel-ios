import Foundation
import Photos

/// Whether an asset's current-version primary resource is on device, probed through
/// `PHAssetResourceManager` with network access disabled (first chunk → local; error → cloud).
/// Results are cached for the process; the prefetcher marks assets local once it pulls them down.
enum AssetLocality {
    private static let cache = LocalityCache()

    static func cachedIsLocal(_ localIdentifier: String) -> Bool? {
        cache.value(for: localIdentifier)
    }

    static func cachedValues(for ids: [String]) -> [String: Bool] {
        cache.values(for: ids)
    }

    static func markLocal(_ localIdentifier: String) {
        cache.set(true, for: localIdentifier)
    }

    /// Classifies ids with at most `maxConcurrent` probes in flight. Cached ids cost nothing.
    /// With a `timeBudget`, probes still running when it expires are cancelled and left out
    /// of the result (unknown).
    static func classify(
        _ ids: [String],
        maxConcurrent: Int,
        timeBudget: Duration? = nil,
        qos: DispatchQoS.QoSClass = .utility
    ) async -> [String: Bool] {
        var result = cache.values(for: ids)
        let pending = ids.filter { result[$0] == nil }
        guard !pending.isEmpty, !Task.isCancelled else { return result }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: pending, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        let width = max(1, maxConcurrent)

        await withTaskGroup(of: (String, Bool?).self) { group in
            var iterator = assets.makeIterator()
            var running = 0
            var stopLaunching = false

            if let timeBudget {
                group.addTask {
                    try? await Task.sleep(for: timeBudget)
                    return (budgetSentinel, nil)
                }
            }
            for _ in 0..<width {
                guard let asset = iterator.next() else { break }
                group.addTask { (asset.localIdentifier, await probe(asset, qos: qos)) }
                running += 1
            }
            if running == 0 { group.cancelAll() }

            while let (id, value) = await group.next() {
                if id == budgetSentinel {
                    if running > 0 {
                        stopLaunching = true
                        group.cancelAll()
                    }
                    continue
                }
                running -= 1
                if let value {
                    result[id] = value
                    cache.set(value, for: id)
                }
                if !stopLaunching, Task.isCancelled {
                    stopLaunching = true
                    group.cancelAll()
                }
                if !stopLaunching, let next = iterator.next() {
                    group.addTask { (next.localIdentifier, await probe(next, qos: qos)) }
                    running += 1
                }
                // All probes done — release the budget timer so the group can return.
                if running == 0 { group.cancelAll() }
            }
        }
        return result
    }

    /// Never a valid localIdentifier; marks the time-budget timer in `classify`.
    private static let budgetSentinel = ""

    /// Local first with a light interleave: the first `lead` slots are local (or unknown), then at
    /// most one cloud-only id per `localRun` local ids, so iCloud assets never form an early streak
    /// and each has a few swipes of prefetch lead time. Input order (already shuffled) is kept
    /// inside each bucket.
    static func localFirstOrder(
        _ ids: [String],
        locality: [String: Bool],
        lead: Int = 4,
        localRun: Int = 4
    ) -> [String] {
        var local: [String] = []
        var unknown: [String] = []
        var cloud: [String] = []
        for id in ids {
            switch locality[id] {
            case .some(true): local.append(id)
            case .some(false): cloud.append(id)
            case .none: unknown.append(id)
            }
        }
        let primary = local + unknown
        guard !cloud.isEmpty else { return primary }
        guard !primary.isEmpty else { return cloud }

        var ordered: [String] = []
        ordered.reserveCapacity(ids.count)
        var p = 0
        var c = 0
        while p < primary.count, p < lead {
            ordered.append(primary[p])
            p += 1
        }
        while p < primary.count || c < cloud.count {
            var run = 0
            while run < localRun, p < primary.count {
                ordered.append(primary[p])
                p += 1
                run += 1
            }
            if c < cloud.count {
                ordered.append(cloud[c])
                c += 1
            }
            if p >= primary.count, c < cloud.count {
                ordered.append(contentsOf: cloud[c...])
                break
            }
        }
        return ordered
    }

    // MARK: - Probe

    /// `true` local, `false` needs network, `nil` unknown (timeout / cancelled / no resource).
    static func probe(_ asset: PHAsset, timeout: TimeInterval = 2, qos: DispatchQoS.QoSClass = .utility) async -> Bool? {
        let state = ProbeState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                guard state.install(continuation) else { return }
                DispatchQueue.global(qos: qos).async {
                    guard !state.isFinished else { return }
                    guard let resource = primaryResource(for: asset) else {
                        state.finish(nil, cancelRequest: false)
                        return
                    }
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = false
                    let requestID = PHAssetResourceManager.default().requestData(
                        for: resource,
                        options: options,
                        dataReceivedHandler: { _ in
                            state.finish(true, cancelRequest: true)
                        },
                        completionHandler: { error in
                            state.finish(error == nil, cancelRequest: false)
                        }
                    )
                    state.setRequestID(requestID)
                    DispatchQueue.global(qos: qos).asyncAfter(deadline: .now() + timeout) {
                        state.finish(nil, cancelRequest: true)
                    }
                }
            }
        } onCancel: {
            state.finish(nil, cancelRequest: true)
        }
    }

    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) {
                return match
            }
        }
        return resources.first
    }
}

/// One-shot continuation + request bookkeeping shared by PhotoKit callbacks, timeout, and cancel.
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?
    private var finished = false
    private var requestID: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
    private var cancelPending = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Returns false (and resumes immediately) if the probe was cancelled before it started.
    func install(_ continuation: CheckedContinuation<Bool?, Never>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelPending
        cancelPending = false
        lock.unlock()
        if cancelNow {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    func finish(_ value: Bool?, cancelRequest: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        continuation = nil
        var toCancel = PHInvalidAssetResourceDataRequestID
        if cancelRequest {
            if requestID != PHInvalidAssetResourceDataRequestID {
                toCancel = requestID
            } else {
                cancelPending = true
            }
        }
        lock.unlock()
        if toCancel != PHInvalidAssetResourceDataRequestID {
            PHAssetResourceManager.default().cancelDataRequest(toCancel)
        }
        pending?.resume(returning: value)
    }
}

private final class LocalityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Bool] = [:]

    func value(for id: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func values(for ids: [String]) -> [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for id in ids {
            if let value = storage[id] {
                out[id] = value
            }
        }
        return out
    }

    func set(_ value: Bool, for id: String) {
        lock.lock()
        storage[id] = value
        lock.unlock()
    }
}
