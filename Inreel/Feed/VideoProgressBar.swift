import SwiftUI
import AVFoundation

/// The card's paging / basket drag runs *simultaneously* with the scrub bar's high-priority
/// drag (`.simultaneousGesture` on the feed stack), so a leftward scrub used to also arm and
/// commit the left-swipe basket. While a scrub is live, card gestures must stand down.
@MainActor
enum VideoScrubGate {
    private(set) static var isScrubbing = false
    static func set(_ scrubbing: Bool) { isScrubbing = scrubbing }
}

/// Feed / Liked paging + basket stand down while center long-press 2× is active
/// (same simultaneous-gesture conflict as `VideoScrubGate`).
@MainActor
enum VideoSpeedGate {
    private(set) static var isBoosting = false
    static func set(_ boosting: Bool) { isBoosting = boosting }
}

/// Thin immersive scrub bar for longer videos (Feed + Liked via FeedCardView).
/// Shown only when `duration >= minimumDuration` (15s). Horizontal drag seeks;
/// vertical Feed / left-swipe basket gestures stay on the rest of the card.
struct VideoProgressBar: View {
    let assetID: String
    let duration: TimeInterval
    var bottomInset: CGFloat

    /// Only show for videos at least this long — short clips stay chrome-free.
    static let minimumDuration: TimeInterval = 15

    private let hitHeight: CGFloat = 36
    private let idleTrackHeight: CGFloat = 2.5
    private let scrubTrackHeight: CGFloat = 4

    @StateObject private var clock = PlayerProgressClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    @State private var wasPlayingBeforeScrub = false
    /// Current touch was claimed as vertical (Feed paging); it never scrubs.
    @State private var touchIsVertical = false

    private var displayFraction: Double {
        min(1, max(0, isScrubbing ? scrubFraction : clock.progress))
    }

    private var effectiveDuration: TimeInterval {
        clock.resolvedDuration(fallback: duration)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    Color.clear
                        .frame(height: hitHeight)
                        .contentShape(Rectangle())
                        .highPriorityGesture(scrubGesture(width: width))

                    track(width: width)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)

                    if isScrubbing {
                        timeLabels
                            .padding(.horizontal, 14)
                            .padding(.bottom, hitHeight + 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: hitHeight + (isScrubbing ? 18 : 0), alignment: .bottom)
            }
            .padding(.bottom, bottomInset)
            .frame(width: width, height: geo.size.height, alignment: .bottom)
        }
        .allowsHitTesting(true)
        .onAppear { clock.attach(assetID: assetID, fallbackDuration: duration) }
        .onDisappear {
            if isScrubbing { VideoScrubGate.set(false) }
            clock.detach()
        }
        .onChange(of: assetID) { _, newID in
            if isScrubbing { VideoScrubGate.set(false) }
            isScrubbing = false
            touchIsVertical = false
            scrubFraction = 0
            wasPlayingBeforeScrub = false
            clock.attach(assetID: newID, fallbackDuration: duration)
        }
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let h = isScrubbing ? scrubTrackHeight : idleTrackHeight
        let fillOpacity: Double = isScrubbing ? 0.92 : 0.50
        let trackOpacity: Double = isScrubbing ? 0.35 : 0.22
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(trackOpacity))
                .frame(height: h)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(fillOpacity))
                .frame(width: max(h, (width - 20) * displayFraction), height: h)
        }
        .frame(height: h)
        .shadow(color: .black.opacity(isScrubbing ? 0.35 : 0.15), radius: isScrubbing ? 3 : 1, y: 1)
        .animation(Motion.scrubChrome, value: isScrubbing)
    }

    private var timeLabels: some View {
        HStack {
            Text(Self.formatTime(effectiveDuration * displayFraction))
                .monospacedDigit()
            Spacer()
            Text(Self.formatTime(effectiveDuration))
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.90))
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)
                if !isScrubbing {
                    // Decide intent before claiming the touch (minimumDistance 0 fires on
                    // touch-down): vertical → leave it to Feed paging for the whole touch;
                    // clear horizontal travel → scrub (and the card gestures stand down).
                    if touchIsVertical { return }
                    if dy > 10, dy > dx * 1.15 {
                        touchIsVertical = true
                        return
                    }
                    guard dx >= 4, dx >= dy else { return }
                    beginScrub()
                }
                let x = min(width, max(0, value.location.x))
                let fraction = width > 0 ? x / width : 0
                scrubFraction = min(1, max(0, fraction))
                clock.seek(to: scrubFraction, exact: false)
            }
            .onEnded { value in
                let wasVertical = touchIsVertical
                touchIsVertical = false
                guard !wasVertical else { return }
                guard isScrubbing else {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard dy <= 12 || dx >= dy else { return }
                    let x = min(width, max(0, value.location.x))
                    let fraction = width > 0 ? x / width : 0
                    scrubFraction = min(1, max(0, fraction))
                    clock.seek(to: scrubFraction, exact: true)
                    clock.setProgress(scrubFraction)
                    return
                }
                // Released within ±2% of an end → snap to the end (no "stuck at 99%").
                // While dragging the fill stays 1:1 (never animated).
                let snap = Motion.scrubEdgeSnapFraction
                let target = scrubFraction <= snap ? 0 : (scrubFraction >= 1 - snap ? 1 : scrubFraction)
                if target != scrubFraction {
                    withAnimation(reduceMotion ? nil : Motion.scrubEdgeSnap) {
                        scrubFraction = target
                        clock.setProgress(target)
                    }
                    Haptics.soft()
                } else {
                    clock.setProgress(target)
                }
                clock.seek(to: target, exact: true)
                endScrub()
            }
    }

    private func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        VideoScrubGate.set(true)
        clock.isScrubbing = true
        scrubFraction = clock.progress
        wasPlayingBeforeScrub = clock.pauseForScrub()
        Haptics.soft()
    }

    private func endScrub() {
        isScrubbing = false
        VideoScrubGate.set(false)
        clock.isScrubbing = false
        if wasPlayingBeforeScrub {
            clock.resumeAfterScrub()
        }
        wasPlayingBeforeScrub = false
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Owns the AVPlayer periodic time observer so SwiftUI view structs don't capture `self`.
@MainActor
final class PlayerProgressClock: ObservableObject {
    @Published var progress: Double = 0
    var isScrubbing = false

    private var assetID: String = ""
    private var fallbackDuration: TimeInterval = 0
    private var timeObserver: Any?
    private weak var player: AVPlayer?
    private var attachTask: Task<Void, Never>?

    func attach(assetID: String, fallbackDuration: TimeInterval) {
        detach()
        self.assetID = assetID
        self.fallbackDuration = fallbackDuration
        progress = 0
        attachTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                if Task.isCancelled { return }
                if self.tryAttach() { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func detach() {
        attachTask?.cancel()
        attachTask = nil
        removeObserver()
        player = nil
        isScrubbing = false
    }

    func setProgress(_ value: Double) {
        progress = min(1, max(0, value))
    }

    func resolvedDuration(fallback: TimeInterval) -> TimeInterval {
        if let item = player?.currentItem {
            let d = item.duration
            if d.isNumeric && !d.isIndefinite {
                let seconds = d.seconds
                if seconds.isFinite, seconds > 0 { return seconds }
            }
        }
        return fallback > 0 ? fallback : fallbackDuration
    }

    @discardableResult
    private func tryAttach() -> Bool {
        guard let live = VideoPlayerPool.shared.existingPlayer(for: assetID),
              live.currentItem != nil else { return false }
        if player === live, timeObserver != nil { return true }
        removeObserver()
        player = live
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        let id = assetID
        timeObserver = live.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isScrubbing else { return }
                guard self.assetID == id else { return }
                let dur = self.resolvedDuration(fallback: self.fallbackDuration)
                guard dur > 0, time.seconds.isFinite else { return }
                self.progress = min(1, max(0, time.seconds / dur))
            }
        }
        let t = live.currentTime().seconds
        let dur = resolvedDuration(fallback: fallbackDuration)
        if t.isFinite, dur > 0 {
            progress = min(1, max(0, t / dur))
        }
        return true
    }

    private func removeObserver() {
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
    }

    func seek(to fraction: Double, exact: Bool) {
        guard let player else { return }
        let dur = resolvedDuration(fallback: fallbackDuration)
        let seconds = dur * min(1, max(0, fraction))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if exact {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let slack = CMTime(seconds: 0.12, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: slack, toleranceAfter: slack)
        }
    }

    /// Returns whether the player was playing before pause.
    func pauseForScrub() -> Bool {
        guard let player else { return false }
        let playing = player.rate > 0.01
        player.pause()
        return playing
    }

    func resumeAfterScrub() {
        player?.play()
    }

}
