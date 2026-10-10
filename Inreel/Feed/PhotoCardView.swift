import SwiftUI
import Photos
import UIKit

struct PhotoCardView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var isDegraded = false
    @State private var isCloudLoading = false
    @State private var loadFailed = false
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    /// Asset the current `image` belongs to (keeps a same-asset frame across re-appear).
    @State private var displayedID: String?
    /// Warm / on-device assets never raise download chrome.
    @State private var suppressCloudChrome = false
    @State private var cloudChromeTask: Task<Void, Never>?
    @Environment(\.feedZoomLocked) private var feedZoomLocked

    private static let manager = FeedImagePrefetcher.shared.manager

    /// Seed first paint from prefetch cache so `.id` remounts never flash black/ProgressView.
    init(asset: PHAsset) {
        self.asset = asset
        let id = asset.localIdentifier
        if let frame = FeedImagePrefetcher.shared.cachedFrame(for: id) {
            _image = State(initialValue: frame.image)
            _isDegraded = State(initialValue: !frame.isHighQuality)
            _displayedID = State(initialValue: id)
            _suppressCloudChrome = State(initialValue: FeedImagePrefetcher.shared.isWarm(id))
        }
    }
    /// Downloads that finish within this window never show the chip (fast networks).
    private static let cloudChromeDelay: UInt64 = 650_000_000

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    ScrollView(.vertical, showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: geo.size.width)
                            .frame(minHeight: geo.size.height)
                            .blur(radius: isCloudLoading ? 3 : 0)
                            .animation(Motion.cloudBlur, value: isCloudLoading)
                    }
                    .scrollDisabled(!isTall(image: image, in: geo.size) || feedZoomLocked)
                } else if loadFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.secondaryText)
                        Text(String(localized: "photo.unavailable"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }

                if isCloudLoading {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.7)
                            Text(String(localized: "photo.icloudDownloading"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                        .padding(.bottom, 120)
                        .transition(.opacity)
                    }
                    .animation(Motion.chromeFast, value: isCloudLoading)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { prepare() }
        .onChange(of: asset.localIdentifier) { _, _ in prepare() }
        .onDisappear {
            cancel()
            hideCloudChrome()
        }
    }

    /// Paint the best cached frame first; only hit PhotoKit when HQ is not already in memory.
    /// Never clear a prior frame to nil on asset change — hold it until new bytes arrive (anti-flash).
    private func prepare() {
        cancel()
        hideCloudChrome()
        loadFailed = false
        let id = asset.localIdentifier
        let prefetcher = FeedImagePrefetcher.shared
        suppressCloudChrome = prefetcher.isWarm(id)
        if let frame = prefetcher.cachedFrame(for: id) {
            image = frame.image
            isDegraded = !frame.isHighQuality
            displayedID = id
        } else if displayedID != id {
            // Keep showing the previous image (stale frame) until the new request returns.
            isDegraded = true
            displayedID = id
        }
        if image != nil, !isDegraded, displayedID == id {
            prefetcher.noteWarm(id)
            return
        }
        load(opportunistic: true)
    }

    private func isTall(image: UIImage, in size: CGSize) -> Bool {
        guard size.width > 0 else { return false }
        let fittedHeight = image.size.height * (size.width / max(image.size.width, 1))
        return fittedHeight > size.height * 1.05
    }

    private func load(opportunistic: Bool) {
        cancel()
        let id = asset.localIdentifier
        let target = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        let options = PHImageRequestOptions()
        options.deliveryMode = opportunistic ? .opportunistic : .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.progressHandler = { progress, error, _, _ in
            Task { @MainActor in
                guard self.asset.localIdentifier == id else { return }
                if error != nil || progress >= 1.0 {
                    // Keep whatever we already have; never crash.
                    self.hideCloudChrome()
                } else {
                    self.scheduleCloudChrome()
                }
            }
        }

        requestID = Self.manager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }

            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil

            Task { @MainActor in
                guard self.asset.localIdentifier == id else { return }
                if let result {
                    self.image = result
                    FeedImagePrefetcher.shared.storeImage(result, for: id, isHighQuality: !degraded)
                    self.isDegraded = degraded
                    self.loadFailed = false
                    if degraded {
                        if inCloud { self.scheduleCloudChrome() }
                        if opportunistic {
                            // Settled high-quality follow-up (may stay degraded offline).
                            self.load(opportunistic: false)
                        }
                    } else {
                        self.hideCloudChrome()
                        FeedImagePrefetcher.shared.noteWarm(id)
                    }
                } else if failed {
                    // No bytes yet — keep placeholder / prior frame.
                    if self.image == nil {
                        self.loadFailed = true
                    }
                    self.hideCloudChrome()
                }
            }
        }
    }

    /// Raise the download chip only for cold iCloud assets still loading after a short delay.
    private func scheduleCloudChrome() {
        guard !suppressCloudChrome, !isCloudLoading, cloudChromeTask == nil else { return }
        let id = asset.localIdentifier
        cloudChromeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.cloudChromeDelay)
            guard !Task.isCancelled else { return }
            self.cloudChromeTask = nil
            guard self.asset.localIdentifier == id,
                  self.image == nil || self.isDegraded else { return }
            withAnimation(Motion.chromeFast) {
                self.isCloudLoading = true
            }
        }
    }

    private func hideCloudChrome() {
        cloudChromeTask?.cancel()
        cloudChromeTask = nil
        if isCloudLoading {
            withAnimation(Motion.chromeFast) {
                isCloudLoading = false
            }
        }
    }

    private func cancel() {
        if requestID != PHInvalidImageRequestID {
            Self.manager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
    }
}
