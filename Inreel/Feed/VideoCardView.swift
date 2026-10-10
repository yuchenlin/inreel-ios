import SwiftUI
import Photos
import AVKit
import AVFoundation
import UIKit

/// Fullscreen looping video card. Tap toggles play/pause; sound follows the global `MuteState`.
struct VideoCardView: View {
    let asset: PHAsset
    /// Increment from parent (single tap) to toggle play/pause without owning the tap gesture.
    var playPauseNonce: Int = 0
    /// Peek/neighbor cards stay attached but paused until they become the front card.
    var isActive: Bool = true

    @AppStorage(AppSettings.autoplayKey) private var autoplay = true
    /// Global, persisted mute (single source of truth shared with Settings + every card).
    /// Read the singleton directly (not `@Environment`): this view lives inside
    /// `ZoomableFeedMedia`'s own UIHostingController, outside the app's environment chain.
    /// `@Observable` tracking still re-renders on change.
    private var muteState: MuteState { MuteState.shared }
    private var isMuted: Bool { muteState.isMuted }

    @State private var player: AVPlayer?
    @State private var isPlaying = true
    /// True only after AVPlayerLayer.isReadyForDisplay — never swap away the poster earlier (anti-flash).
    @State private var isReady = false
    @State private var loadFailed = false
    @State private var poster: UIImage?
    @State private var endObserver: NSObjectProtocol?
    @State private var playerItemRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var posterRequestID: PHImageRequestID = PHInvalidImageRequestID
    /// Invalidates in-flight PhotoKit callbacks after swipe-away / teardown.
    @State private var loadGeneration = UUID()
    /// Delayed so warm / fast items never flash the warming spinner.
    @State private var showWarmingHint = false
    @State private var warmingHintTask: Task<Void, Never>?

    private static var imageManager: PHCachingImageManager { FeedImagePrefetcher.shared.manager }
    private static let warmingHintDelay: UInt64 = 700_000_000

    /// Seed poster from prefetch so first paint after `.id` remount is never empty black.
    init(asset: PHAsset, playPauseNonce: Int = 0, isActive: Bool = true) {
        self.asset = asset
        self.playPauseNonce = playPauseNonce
        self.isActive = isActive
        if let cached = FeedImagePrefetcher.shared.cachedImage(for: asset.localIdentifier) {
            _poster = State(initialValue: cached)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                // Mount the layer as soon as we have a player so KVO can observe isReadyForDisplay,
                // but keep it invisible until the first frame is actually composited.
                if let player {
                    VideoPlayerView(player: player) { ready in
                        guard ready else { return }
                        // Only promote when this generation still owns the card.
                        if !isReady {
                            isReady = true
                            loadFailed = false
                            hideWarmingHint()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(isReady ? 1 : 0)
                    .allowsHitTesting(false)
                }

                // Poster / last frame stays on top until the player layer is ready to display.
                // Same idea as PhotoCardView: never clear to nil before the next frame is ready.
                if let poster, !isReady {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                } else if player == nil, poster == nil, loadFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.secondaryText)
                        Text(String(localized: "video.unavailable"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .allowsHitTesting(false)
                } else if player == nil, poster == nil, !loadFailed {
                    ProgressView()
                        .tint(.white)
                        .allowsHitTesting(false)
                }

                if !isPlaying, isReady {
                    Image(systemName: "play.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        .allowsHitTesting(false)
                }

                // Poster/last-frame visible but a cold (iCloud) player still warming — keep frame, soft hint.
                if showWarmingHint, poster != nil, !isReady, !loadFailed {
                    VStack {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.7)
                            .padding(8)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                            .padding(.bottom, 120)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            isPlaying = autoplay && isActive
            seedPosterFromCache()
            loadPoster()
            attachPlayer()
            scheduleWarmingHint()
            applyActiveState()
        }
        .onChange(of: isActive) { _, active in
            if active {
                // Re-attach after tab keep-alive teardown (Liked viewer may have used the pool).
                if player == nil {
                    seedPosterFromCache()
                    loadPoster()
                    attachPlayer()
                    scheduleWarmingHint()
                }
                applyActiveState()
            } else {
                // Free the pool entry + detach layer so another host (Liked viewer) can play.
                // Poster stays painted — opacity-0 Feed must never flash black on return.
                detachForInactivity()
            }
        }
        .onChange(of: asset.localIdentifier) { _, _ in
            // Soft reset: keep prior poster painted; do not nil the layer/poster before the next frame.
            softResetForNewAsset()
            isPlaying = autoplay
            seedPosterFromCache()
            loadPoster()
            attachPlayer()
            scheduleWarmingHint()
        }
        .onChange(of: isMuted) { _, muted in
            if let player {
                VideoPlayerPool.shared.applyMute(muted, to: player)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inreelVideoPlayerEvicted)) { note in
            // Pool reclaimed our player (LRU / memory warning): cover with the poster now, before
            // the item is cleared; `onChange(of: isActive)` re-attaches when this card is shown.
            guard let id = note.object as? String, id == asset.localIdentifier, player != nil else { return }
            handleEviction()
        }
        .onChange(of: playPauseNonce) { oldValue, newValue in
            guard newValue != oldValue else { return }
            togglePlayPause()
        }
        .onDisappear {
            teardown()
        }
    }

    private func togglePlayPause() {
        guard let player, isReady else { return }
        if isPlaying {
            if VideoSpeedGate.isBoosting { VideoSpeedGate.set(false) }
            player.rate = 1
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        Haptics.light()
    }

    private func attachPlayer() {
        let id = asset.localIdentifier
        let generation = UUID()
        loadGeneration = generation

        let pooled = VideoPlayerPool.shared.acquire(for: id)
        VideoPlayerPool.shared.setActive(id, isActive)
        VideoPlayerPool.shared.applyMute(isMuted, to: pooled)
        // Cover with poster until isReadyForDisplay — never flash a black empty layer.
        isReady = false
        player = pooled

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        playerItemRequestID = Self.imageManager.requestPlayerItem(
            forVideo: asset,
            options: options
        ) { item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }
            Task { @MainActor in
                guard generation == self.loadGeneration else { return }
                guard self.asset.localIdentifier == id else { return }

                if info?[PHImageErrorKey] != nil {
                    self.loadFailed = self.poster == nil
                    return
                }
                guard let item else {
                    self.loadFailed = self.poster == nil
                    return
                }

                let player = VideoPlayerPool.shared.acquire(for: id)
                // Keep poster overlay until the new item's first frame is ready (anti-flash on replace).
                self.isReady = false
                player.replaceCurrentItem(with: item)
                // Async PhotoKit hop: read the singleton (same object as the environment value).
                VideoPlayerPool.shared.applyMute(MuteState.shared.isMuted, to: player)
                self.installLoopObserver(for: item, player: player)
                self.player = player
                self.loadFailed = false
                FeedImagePrefetcher.shared.noteWarm(id)
                // Play under the poster; VideoPlayerView KVO promotes isReady when the layer has a frame.
                if self.isActive && self.isPlaying {
                    player.play()
                } else {
                    player.pause()
                    self.isPlaying = false
                }
            }
        }
    }

    private func installLoopObserver(for item: AVPlayerItem, player: AVPlayer) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            guard let player else { return }
            // `play()` forces rate=1; keep 2× if a center long-press boost is still held.
            Task { @MainActor in
                let boost = VideoSpeedGate.isBoosting
                player.seek(to: .zero)
                if boost {
                    player.rate = 2
                } else {
                    player.play()
                }
            }
        }
    }

    private func loadPoster() {
        let target = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let id = asset.localIdentifier
        let generation = loadGeneration
        posterRequestID = Self.imageManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let result {
                Task { @MainActor in
                    guard generation == self.loadGeneration else { return }
                    guard self.asset.localIdentifier == id else { return }
                    self.poster = result
                    FeedImagePrefetcher.shared.storeImage(result, for: id, isHighQuality: !degraded)
                }
            }
        }
    }

    private func scheduleWarmingHint() {
        hideWarmingHint()
        let id = asset.localIdentifier
        guard !FeedImagePrefetcher.shared.isWarm(id) else { return }
        warmingHintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.warmingHintDelay)
            guard !Task.isCancelled, self.asset.localIdentifier == id, !self.isReady else { return }
            withAnimation(Motion.chromeFast) {
                self.showWarmingHint = true
            }
        }
    }

    private func hideWarmingHint() {
        warmingHintTask?.cancel()
        warmingHintTask = nil
        showWarmingHint = false
    }

    private func seedPosterFromCache() {
        // Only replace when we have a frame for the *new* asset — never nil-out the
        // previous poster (holds last frame across swipe until the next poster arrives).
        if let cached = FeedImagePrefetcher.shared.cachedImage(for: asset.localIdentifier) {
            poster = cached
        }
    }

    private func applyActiveState() {
        guard let player else { return }
        VideoPlayerPool.shared.setActive(asset.localIdentifier, isActive)
        if isActive {
            if autoplay {
                player.play()
                isPlaying = true
            }
        } else {
            player.pause()
            isPlaying = false
        }
    }

    /// Tab keep-alive hid this card — release pool + drop layer; keep poster for return.
    private func detachForInactivity() {
        loadGeneration = UUID()
        hideWarmingHint()
        isReady = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if playerItemRequestID != PHInvalidImageRequestID {
            Self.imageManager.cancelImageRequest(playerItemRequestID)
            playerItemRequestID = PHInvalidImageRequestID
        }
        if posterRequestID != PHInvalidImageRequestID {
            Self.imageManager.cancelImageRequest(posterRequestID)
            posterRequestID = PHInvalidImageRequestID
        }
        if let player {
            player.rate = 1
            player.pause()
        }
        if VideoSpeedGate.isBoosting { VideoSpeedGate.set(false) }
        // Release whatever id this player was pooled under (current asset).
        VideoPlayerPool.shared.release(asset.localIdentifier)
        player = nil
        isPlaying = false
    }

    /// Evicted by the pool: same as an inactivity detach (poster stays painted, layer dropped).
    private func handleEviction() {
        detachForInactivity()
        if isActive {
            // Only possible if every pooled player was active — get a fresh one next turn.
            Task { @MainActor in
                guard player == nil, isActive else { return }
                attachPlayer()
                scheduleWarmingHint()
                applyActiveState()
            }
        }
    }

    /// Cancel in-flight work and detach playback, but keep `poster` so settle never paints black.
    private func softResetForNewAsset() {
        loadGeneration = UUID()
        hideWarmingHint()
        // Cover with poster BEFORE detaching the layer / releasing the pool entry.
        isReady = false
        loadFailed = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if playerItemRequestID != PHInvalidImageRequestID {
            Self.imageManager.cancelImageRequest(playerItemRequestID)
            playerItemRequestID = PHInvalidImageRequestID
        }
        if posterRequestID != PHInvalidImageRequestID {
            Self.imageManager.cancelImageRequest(posterRequestID)
            posterRequestID = PHInvalidImageRequestID
        }
        let id = asset.localIdentifier
        if let player {
            player.rate = 1
            player.pause()
        }
        if VideoSpeedGate.isBoosting { VideoSpeedGate.set(false) }
        VideoPlayerPool.shared.release(id)
        // Drop the layer host; poster stays painted (never nil'd here).
        player = nil
    }

    private func teardown() {
        softResetForNewAsset()
        // Leaving the card: pool already released. Poster may linger in state until dealloc;
        // do not force poster = nil (avoids a black flash if SwiftUI paints one more frame).
    }
}

/// Bare AVPlayerLayer host without AVKit transport controls.
/// Reports `isReadyForDisplay` so the SwiftUI poster can stay up until the first frame is composited.
private struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    var onReadyForDisplay: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReadyForDisplay: onReadyForDisplay)
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        context.coordinator.onReadyForDisplay = onReadyForDisplay
        if uiView.playerLayer.player !== player {
            // Item / player swap → layer goes not-ready; keep poster until the new frame lands.
            context.coordinator.onReadyForDisplay(false)
            uiView.playerLayer.player = player
            context.coordinator.attach(to: uiView.playerLayer)
        } else {
            context.coordinator.attach(to: uiView.playerLayer)
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.detach()
        // Do not assign player = nil here during settle — parent already released the pool entry.
        // Clearing the layer on dismantle can flash black for one frame under a transitioning card.
    }

    /// Main-actor isolated: KVO may fire on any thread, so the observation hops to the main
    /// actor with only a Bool (no captured non-Sendable state).
    @MainActor
    final class Coordinator {
        var onReadyForDisplay: (Bool) -> Void
        private var observation: NSKeyValueObservation?
        private weak var observedLayer: AVPlayerLayer?

        init(onReadyForDisplay: @escaping (Bool) -> Void) {
            self.onReadyForDisplay = onReadyForDisplay
        }

        func attach(to layer: AVPlayerLayer) {
            if observedLayer === layer, observation != nil {
                // Re-publish current value (e.g. already-ready pooled player).
                onReadyForDisplay(layer.isReadyForDisplay)
                return
            }
            observation?.invalidate()
            observedLayer = layer
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    self?.onReadyForDisplay(ready)
                }
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            observedLayer = nil
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Transparent so the SwiftUI poster underlay shows through until ready.
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
