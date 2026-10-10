import SwiftUI
import Photos
import SwiftData
import AVFoundation

struct FeedCardView: View {
    let asset: PHAsset
    var showsSideActions: Bool = true
    /// When false, single tap does not toggle playback (viewer may still pass playPause).
    var allowsVideoTapPause: Bool = true
    /// Bumped by parent after notes sheet dismiss — refresh badge without remounting the card.
    var notesRefreshToken: Int = 0
    var onBasket: (() -> Void)? = nil
    var onNotes: (() -> Void)? = nil
    /// Parent feed sets this so paging gestures don't run while the card is zoomed.
    var zoomLock: Binding<Bool> = .constant(false)
    /// False for the off-screen peek neighbor — pause video / ignore chrome taps.
    var isActiveCard: Bool = true
    /// When true (tab bar Always visible, or Auto-hide after reveal), raise meta +
    /// side actions above the floating tab pill. Media stays full-bleed.
    var tabBarVisible: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AppSettings.showDateKey) private var showDate = true
    @AppStorage(AppSettings.showExactDatesKey) private var showExactDates = true
    @AppStorage(AppSettings.showSizeKey) private var showSize = false
    @AppStorage(AppSettings.showTimeKey) private var showTime = true
    @AppStorage(AppSettings.showLocationKey) private var showLocation = true
    @AppStorage(AppSettings.showDeviceKey) private var showDevice = true
    @AppStorage(AppSettings.showAlbumsKey) private var showAlbums = true
    /// Global, persisted mute — shared by every card, the pool, and Settings.
    @Environment(MuteState.self) private var muteState
    private var isMuted: Bool { muteState.isMuted }

    @State private var isFavorite = false
    @State private var showChrome = true
    @State private var showHeartBurst = false
    @State private var playPauseNonce = 0
    @State private var heartBurstToken = 0
    /// Bumped when a favorite write fails and the heart rolls back (drives the shake).
    @State private var favoriteRollbackTick = 0
    @State private var favoriteRollbackFlash = false
    @State private var noteCount = 0
    @State private var estimatedByteCount: Int64 = 0
    @State private var locationText: String?
    @State private var deviceText: String?
    @State private var albumsText: String?
    @State private var metaLoadToken = 0
    @State private var isPreparingShare = false
    @State private var sharePayload: SharePayload?
    @State private var isZoomed = false
    @State private var zoomResetTick = 0
    @State private var isSpeedBoosting = false
    @State private var showSpeedHUD = false
    /// Swallow the tap that fires when the finger lifts after a 2× hold.
    @State private var suppressTapAfterBoost = false

    /// Immersive TikTok-ish side actions — ~64pt circle / hit (larger than build 18's 48).
    private let actionHit: CGFloat = 64
    private let actionIconSize: CGFloat = 28

    private var isVideo: Bool { asset.mediaType == .video }

    private var fileSizeText: String? {
        guard estimatedByteCount > 0 else { return nil }
        return BasketStore.formatByteCount(estimatedByteCount)
    }

    private var timeText: String? {
        guard showTime, let date = asset.creationDate else { return nil }
        return AssetMetadata.timeText(from: date)
    }

    private var showsMeta: Bool {
        (showDate && asset.creationDate != nil)
            || timeText != nil
            || (isVideo && asset.duration > 0)
            || (showSize && fileSizeText != nil)
            || (showLocation && locationText != nil)
            || (showDevice && deviceText != nil)
            || (showAlbums && albumsText != nil)
    }

    /// Immersive Feed uses 28pt above the home indicator. When the floating tab
    /// is visible, raise meta/actions by the shared clearance (bar + gap).
    private var chromeBottomPad: CGFloat {
        tabBarVisible ? Theme.floatingTabChromeBottomPad : 28
    }

    private var overlayGradientHeight: CGFloat {
        let base: CGFloat = showsMeta ? 188 : 140
        return tabBarVisible ? base + Theme.floatingTabClearance : base
    }

    /// Progress bar sits just above the floating tab pill (or home indicator),
    /// below meta / side-action circles so it never covers them.
    /// Tab visible: HI(~34) + tab pad(8) + capsule(~52) + 4pt gap ≈ 98.
    /// Meta/actions use chromeBottomPad 114 → ~16pt air above the bar.
    private var progressBarBottomInset: CGFloat {
        tabBarVisible ? (34 + 8 + 52 + 4) : 10
    }

    private var showsVideoProgress: Bool {
        isVideo && isActiveCard && asset.duration >= VideoProgressBar.minimumDuration
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZoomableFeedMedia(
                resetID: asset.localIdentifier,
                isZoomed: $isZoomed,
                resetTick: zoomResetTick,
                speedBoostEnabled: isVideo && isActiveCard,
                onSpeedBoostChanged: { active in
                    if active {
                        beginSpeedBoost()
                    } else {
                        endSpeedBoost(restoreRate: true)
                    }
                }
            ) {
                if isVideo {
                    VideoCardView(asset: asset, playPauseNonce: playPauseNonce, isActive: isActiveCard)
                } else {
                    PhotoCardView(asset: asset)
                }
            }

            if showChrome {
                VStack {
                    Spacer()
                    Theme.overlayGradient
                        .frame(height: overlayGradientHeight)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .bottom)

                HStack(alignment: .bottom, spacing: 12) {
                    if showsMeta {
                        VStack(alignment: .leading, spacing: 3) {
                            if showDate, let date = asset.creationDate {
                                Text(AssetMetadata.dateText(from: date, exact: showExactDates))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.primaryText)
                            }
                            if let timeText {
                                metaLine(systemName: "clock", text: timeText)
                            }
                            if isVideo, asset.duration > 0 {
                                Text(formatDuration(asset.duration))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            if showSize, let sizeText = fileSizeText {
                                Text(sizeText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            if showLocation, let locationText {
                                metaLine(systemName: "mappin.and.ellipse", text: locationText)
                            }
                            if showDevice, let deviceText {
                                metaLine(systemName: "camera", text: deviceText)
                            }
                            if showAlbums, let albumsText {
                                metaLine(systemName: "rectangle.stack", text: albumsText)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.floatingFill)
                        )
                        .padding(.leading, 16)
                        .padding(.bottom, chromeBottomPad)
                    }

                    Spacer(minLength: 0)

                    if showsSideActions {
                        VStack(spacing: 14) {
                            if isVideo {
                                Button {
                                    toggleMute()
                                } label: {
                                    floatingIcon(
                                        systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                                    )
                                }
                                .buttonStyle(PressScaleButtonStyle())
                                .accessibilityLabel(
                                    Text(isMuted
                                         ? String(localized: "video.unmute")
                                         : String(localized: "video.mute"))
                                )
                            }

                            Button {
                                toggleFavorite(burst: false)
                            } label: {
                                floatingIcon(
                                    systemName: isFavorite ? "heart.fill" : "heart",
                                    tint: isFavorite ? Color.red.opacity(0.95) : .white
                                )
                                .scaleEffect(isFavorite && !reduceMotion ? 1.05 : 1)
                                // Write failed → brief shake + amber flash so the rollback isn't silent.
                                .modifier(ShakeEffect(travel: reduceMotion ? 0 : Motion.favoriteRollbackShakeTravel,
                                                      animatableData: CGFloat(favoriteRollbackTick)))
                                .overlay {
                                    Circle()
                                        .stroke(Color.orange.opacity(favoriteRollbackFlash ? 0.9 : 0), lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityLabel(
                                Text(isFavorite
                                     ? String(localized: "like.unlike")
                                     : String(localized: "like.like"))
                            )

                            Button {
                                Task { await shareCurrentAsset() }
                            } label: {
                                ZStack {
                                    floatingIcon(systemName: "square.and.arrow.up")
                                        .opacity(isPreparingShare ? 0.35 : 1)
                                    if isPreparingShare {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .tint(.white)
                                            .scaleEffect(0.9)
                                    }
                                }
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .disabled(isPreparingShare)
                            .accessibilityLabel(Text(String(localized: "share.share")))

                            if let onNotes {
                                Button(action: onNotes) {
                                    ZStack(alignment: .topTrailing) {
                                        floatingIcon(systemName: "bubble.right.fill")

                                        if noteCount > 0 {
                                            Text(noteCount > 99 ? "99+" : "\(noteCount)")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.black)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.accent))
                                                .offset(x: 6, y: -2)
                                        }
                                    }
                                }
                                .buttonStyle(PressScaleButtonStyle())
                                .accessibilityLabel(Text(String(localized: "notes.open")))
                            }

                            if let onBasket {
                                Button(action: onBasket) {
                                    floatingIcon(systemName: "trash.fill")
                                }
                                .buttonStyle(PressScaleButtonStyle())
                                .accessibilityLabel(Text(String(localized: "basket.add")))
                            }
                        }
                        .padding(.trailing, 8)
                        .padding(.bottom, chromeBottomPad)
                    }
                }
                .transition(.opacity)
            }

            if showHeartBurst {
                Image(systemName: "heart.fill")
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    // Enter from 0.92 (not 0.4 = "from nothing"). Reduce Motion: opacity only.
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: Motion.heartBurstStartScale).combined(with: .opacity))
                    // Center on the card — the parent ZStack is bottom-aligned, which used to
                    // park the burst behind the tab bar.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            // Long-video scrub bar — outside ZoomableFeedMedia so pinch-zoom
            // doesn't scale it; above floating tab, below meta/side actions.
            if showsVideoProgress {
                VideoProgressBar(
                    assetID: asset.localIdentifier,
                    duration: asset.duration,
                    bottomInset: progressBarBottomInset
                )
                .zIndex(5)
            }

            if showSpeedHUD {
                // Subtle bottom tip (not center-stage): small, translucent, near scrub/chrome.
                HStack(spacing: 3) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(String(localized: "video.speed.2x"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .padding(.bottom, progressBarBottomInset + (showsVideoProgress ? 22 : 14))
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .zIndex(6)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(isActiveCard)
        .onTapGesture(count: 2) {
            // 1x keeps double-tap like. While zoomed, double-tap snaps back to 1x
            // (the pinch recognizer also handles this) and does not toggle favorite.
            if isZoomed {
                zoomResetTick += 1
                return
            }
            toggleFavorite(burst: true)
        }
        .onTapGesture(count: 1) {
            handleSingleTap()
        }
        .onAppear {
            isZoomed = false
            zoomLock.wrappedValue = false
            isFavorite = FavoriteQueue.shared.pendingValue(for: asset.localIdentifier) ?? asset.isFavorite
            showChrome = true
            refreshNoteCount()
            refreshFileSize()
            refreshOptionalMeta()
            if isVideo {
                // Idempotent; app launch already started it — belt-and-suspenders for KVO.
                muteState.startObservingVolumeKeys()
            }
            // QA: `defaults write … debugPresentShareOnce 1` — present share sheet once.
            let shareKey = "debugPresentShareOnce"
            if UserDefaults.standard.bool(forKey: shareKey) {
                UserDefaults.standard.removeObject(forKey: shareKey)
                Task { await shareCurrentAsset() }
            }
        }
        .onChange(of: notesRefreshToken) { _, _ in
            refreshNoteCount()
        }
        .onChange(of: isZoomed) { _, zoomed in
            if zoomed { endSpeedBoost(restoreRate: true) }
            zoomLock.wrappedValue = zoomed
        }
        .onChange(of: isActiveCard) { _, active in
            if !active { endSpeedBoost(restoreRate: true) }
        }
        .onDisappear {
            endSpeedBoost(restoreRate: true)
            if zoomLock.wrappedValue {
                zoomLock.wrappedValue = false
            }
        }
        .onChange(of: asset.localIdentifier) { _, _ in
            endSpeedBoost(restoreRate: true)
            // Mute is global (MuteState) — a new asset keeps whatever the user chose last.
            isFavorite = FavoriteQueue.shared.pendingValue(for: asset.localIdentifier) ?? asset.isFavorite
            showChrome = true
            showHeartBurst = false
            playPauseNonce = 0
            locationText = nil
            deviceText = nil
            albumsText = nil
            isPreparingShare = false
            refreshNoteCount()
            refreshFileSize()
            refreshOptionalMeta()
        }
        .onChange(of: showLocation) { _, _ in refreshOptionalMeta() }
        .onChange(of: showDevice) { _, _ in refreshOptionalMeta() }
        .onChange(of: showAlbums) { _, _ in refreshOptionalMeta() }
        .onReceive(NotificationCenter.default.publisher(for: .inreelFavoriteWriteFailed)) { note in
            guard let id = note.object as? String,
                  id == asset.localIdentifier,
                  let restored = note.userInfo?["isFavorite"] as? Bool else { return }
            withAnimation(reduceMotion ? Motion.reducedLikeToggle : Motion.likeToggle) {
                isFavorite = restored
            }
            withAnimation(.linear(duration: Motion.favoriteRollbackShake)) {
                favoriteRollbackTick += 1
            }
            withAnimation(Motion.chromeFast) {
                favoriteRollbackFlash = true
            } completion: {
                withAnimation(Motion.favoriteRollbackFlashOut) {
                    favoriteRollbackFlash = false
                }
            }
            Haptics.warning()
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
        }
    }

    private func metaLine(systemName: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private func floatingIcon(systemName: String, tint: Color = .white) -> some View {
        Image(systemName: systemName)
            .font(.system(size: actionIconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: actionHit, height: actionHit)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(Theme.floatingFill)
            )
    }

    private func refreshFileSize() {
        estimatedByteCount = BasketStore.estimatedByteCount(for: asset)
    }

    private func refreshNoteCount() {
        noteCount = (try? NoteStore(context: modelContext).noteCount(for: asset.localIdentifier)) ?? 0
    }

    private func refreshOptionalMeta() {
        metaLoadToken += 1
        let token = metaLoadToken
        let current = asset

        if !showLocation { locationText = nil }
        if !showDevice { deviceText = nil }
        if !showAlbums { albumsText = nil }

        guard showLocation || showDevice || showAlbums else { return }

        Task {
            var nextLocation: String?
            var nextDevice: String?
            var nextAlbums: String?
            if showLocation {
                nextLocation = await AssetMetadata.locationText(for: current)
            }
            if showDevice {
                nextDevice = await AssetMetadata.deviceText(for: current)
            }
            if showAlbums {
                nextAlbums = AssetMetadata.albumText(for: current)
            }
            await MainActor.run {
                guard token == metaLoadToken, current.localIdentifier == asset.localIdentifier else { return }
                if showLocation { locationText = nextLocation }
                if showDevice { deviceText = nextDevice }
                if showAlbums { albumsText = nextAlbums }
            }
        }
    }

    @MainActor
    private func shareCurrentAsset() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        do {
            let items = try await AssetShare.activityItems(for: asset)
            sharePayload = SharePayload(items: items)
            Haptics.light()
        } catch {
            Haptics.medium()
        }
    }

    /// Global toggle: persists + applies to every pooled player (current, peek, next loads).
    private func toggleMute() {
        if isMuted {
            VideoPlayerPool.shared.activatePlaybackSessionIfNeeded()
        }
        muteState.toggle()
        Haptics.light()
    }

    private func handleSingleTap() {
        if suppressTapAfterBoost {
            suppressTapAfterBoost = false
            return
        }
        if isVideo, allowsVideoTapPause {
            playPauseNonce += 1
        } else if !isVideo {
            withAnimation(reduceMotion ? Motion.reduced : Motion.chromeFast) {
                showChrome.toggle()
            }
        }
    }

    /// Optimistic: heart state, burst, and haptic happen now; PhotoKit + Stats persist in the
    /// background via `FavoriteQueue`, which rolls the heart back on failure.
    @MainActor
    private func toggleFavorite(burst: Bool) {
        let previous = isFavorite
        let target = !previous
        withAnimation(reduceMotion ? Motion.reducedLikeToggle : Motion.likeToggle) {
            isFavorite = target
        }
        Haptics.like()
        if target && burst {
            playHeartBurst()
        }
        FavoriteQueue.shared.setFavorite(
            target,
            for: asset,
            previous: previous,
            container: modelContext.container
        )
    }

    @MainActor
    private func playHeartBurst() {
        heartBurstToken += 1
        let token = heartBurstToken
        withAnimation(reduceMotion ? Motion.reduced : Motion.heartBurstIn) {
            showHeartBurst = true
        }
        Task { @MainActor in
            // Short hold so total visible time stays ≲350ms (rapid likes don't stack motion).
            try? await Task.sleep(nanoseconds: Motion.heartBurstHold)
            guard token == heartBurstToken else { return }
            withAnimation(reduceMotion ? Motion.reduced : Motion.heartBurstOut) {
                showHeartBurst = false
            }
        }
    }


    // MARK: - Center long-press 2× (UIKit recognizer on ZoomableFeedMedia)

    private func beginSpeedBoost() {
        guard !isSpeedBoosting else { return }
        guard !isZoomed, isVideo, isActiveCard else { return }
        guard !VideoScrubGate.isScrubbing else { return }
        guard let player = VideoPlayerPool.shared.existingPlayer(for: asset.localIdentifier) else { return }
        // Only speed up while already playing; paused → no-op.
        guard player.rate > 0.01 else { return }
        isSpeedBoosting = true
        suppressTapAfterBoost = true
        VideoSpeedGate.set(true)
        player.rate = 2
        Haptics.soft()
        showSpeedHUD = true
    }

    private func endSpeedBoost(restoreRate: Bool) {
        guard isSpeedBoosting || VideoSpeedGate.isBoosting || showSpeedHUD else { return }
        isSpeedBoosting = false
        VideoSpeedGate.set(false)
        if restoreRate, let player = VideoPlayerPool.shared.existingPlayer(for: asset.localIdentifier) {
            // Still playing → back to 1×; if paused, leave rate alone (pause owns it).
            if player.rate > 0.01 {
                player.rate = 1
            }
        }
        // Drop immediately on finger-up — no fade-out linger.
        showSpeedHUD = false
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}


/// Horizontal "no" shake: three damped oscillations per unit of `animatableData`.
/// Animate `animatableData` +1 (linear) to play one shake; travel 0 = disabled (Reduce Motion).
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = animatableData - animatableData.rounded(.down)
        let dx = travel * (1 - phase) * sin(phase * .pi * 6)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
