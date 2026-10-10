import SwiftUI
import Photos
import SwiftData
import UIKit

/// Fullscreen liked-set viewer. Vertical walks the collection; left-swipe / trash → basket.
struct LikedViewerView: View {
    let assets: [PHAsset]
    @Binding var index: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(BasketFlyController.self) private var basketFly
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sessionAssets: [PHAsset]
    @State private var dragOffset: CGSize = .zero
    @State private var basketDragRaw: CGFloat = 0
    @State private var crossedBasketThreshold = false
    @State private var crossedBasketAt: Date?
    @State private var cardZoomed = false
    /// This touch is a long-video scrub — never page or basket it.
    @State private var gestureSawScrub = false
    @State private var isCommitting = false
    /// Departing-card fade on basket commit (hands off to the fly thumb).
    @State private var cardFade: Double = 1

    private let swipeThreshold: CGFloat = 80
    private let basketAxisRatio: CGFloat = 1.35
    private let basketDwellSeconds: TimeInterval = 0.12

    init(assets: [PHAsset], index: Binding<Int>) {
        self.assets = assets
        self._index = index
        // Seed immediately — empty @State + onAppear left the first frame (and
        // sometimes the whole cover) on Theme.background only (= black screen).
        _sessionAssets = State(initialValue: assets)
    }

    private var basketSwipeThreshold: CGFloat {
        let w = UIScreen.main.bounds.width
        return max(160, min(180, w * 0.42))
    }

    private var basketProgress: CGFloat {
        min(1, max(0, -basketDragRaw / basketSwipeThreshold))
    }

    private var basketDisplayX: CGFloat {
        if dragOffset.width < -basketSwipeThreshold * 1.5 {
            return dragOffset.width
        }
        let raw = basketDragRaw
        let t = basketSwipeThreshold
        if -raw <= t { return raw }
        let excess = -raw - t
        return -(t + excess * 0.35)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if basketDragRaw < -16 {
                basketAffordance
            }

            if sessionAssets.indices.contains(index) {
                FeedCardView(
                    asset: sessionAssets[index],
                    onBasket: { Task { await commitBasket() } },
                    zoomLock: $cardZoomed
                )
                .id(sessionAssets[index].localIdentifier)
                .offset(x: basketDisplayX, y: dragOffset.height)
                .rotationEffect(.degrees(Double(min(0, basketDisplayX)) / 36.0))
                .scaleEffect(
                    basketDragRaw < -16
                        ? max(0.94, 1 + basketDragRaw / 1400)
                        : 1
                )
                .overlay {
                    if basketProgress >= 1 {
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Theme.accent.opacity(0.55), lineWidth: 2.5)
                            .allowsHitTesting(false)
                    }
                }
                .brightness(basketProgress >= 1 ? -0.06 : 0)
                .opacity(cardFade)
                .simultaneousGesture(pagingGesture)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(Color.white.opacity(0.16)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Spacer()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden(true)
        .onAppear {
            if sessionAssets.isEmpty, !assets.isEmpty {
                sessionAssets = assets
            }
            if !sessionAssets.indices.contains(index) {
                index = min(max(0, index), max(0, sessionAssets.count - 1))
            }
            // Ensure Feed's keep-alive hosts released any shared AVPlayers.
            VideoPlayerPool.shared.releaseAll()
            Haptics.prepare()
        }
        .onChange(of: cardZoomed) { _, zoomed in
            if zoomed {
                dragOffset = .zero
                basketDragRaw = 0
            }
        }
    }

    private var basketAffordance: some View {
        let armed = basketProgress >= 1
        return ZStack {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.0),
                        Color.red.opacity(0.18 + 0.35 * Double(basketProgress) + (armed ? 0.12 : 0))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 180)
            }
            .allowsHitTesting(false)

            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(armed ? Theme.accent : .white)
                        .scaleEffect(0.82 + 0.42 * basketProgress)
                    Text(String(localized: "basket.add"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .opacity(Double(min(1, basketProgress * 1.4)))
                }
                .padding(.trailing, 26)
            }
        }
        .opacity(Double(min(1, basketProgress * 1.15)))
        .animation(reduceMotion ? Motion.reduced : Motion.basketArm, value: armed)
    }

    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard !cardZoomed, !isCommitting else {
                    dragOffset = .zero
                    basketDragRaw = 0
                    return
                }
                if VideoScrubGate.isScrubbing || VideoSpeedGate.isBoosting || gestureSawScrub {
                    if !gestureSawScrub {
                        gestureSawScrub = true
                        dragOffset = .zero
                        basketDragRaw = 0
                    }
                    return
                }
                let dy = value.translation.height
                let dx = value.translation.width
                if abs(dx) > abs(dy) * basketAxisRatio {
                    let raw = min(0, dx)
                    basketDragRaw = raw
                    dragOffset = CGSize(width: raw, height: 0)
                    let past = raw <= -basketSwipeThreshold
                    if past, !crossedBasketThreshold {
                        crossedBasketThreshold = true
                        crossedBasketAt = Date()
                        Haptics.basketThreshold()
                    } else if !past, crossedBasketThreshold {
                        crossedBasketThreshold = false
                        crossedBasketAt = nil
                        Haptics.light()
                    }
                } else {
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                    basketDragRaw = 0
                    dragOffset = CGSize(width: 0, height: dy * 0.85)
                }
            }
            .onEnded { value in
                if gestureSawScrub {
                    gestureSawScrub = false
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                    return
                }
                guard !cardZoomed, !isCommitting else {
                    dragOffset = .zero
                    basketDragRaw = 0
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                    return
                }
                let dy = value.translation.height
                let dx = value.translation.width
                let predictedX = value.predictedEndTranslation.width
                let dwellOK: Bool = {
                    guard let t = crossedBasketAt else { return false }
                    return Date().timeIntervalSince(t) >= basketDwellSeconds
                }()
                defer {
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                }

                if abs(dx) > abs(dy) * basketAxisRatio {
                    let pastNow = dx <= -basketSwipeThreshold
                    let predictedPast = predictedX < -basketSwipeThreshold
                    let shouldBasket = (pastNow && (predictedPast || dwellOK))
                        || min(dx, predictedX) < -basketSwipeThreshold
                    if shouldBasket {
                        let releaseVelocity = value.velocity
                        Task { await commitBasket(releaseVelocity: releaseVelocity) }
                    } else {
                        withAnimation(reduceMotion ? Motion.reduced : Motion.basketCancel) {
                            dragOffset = .zero
                            basketDragRaw = 0
                        }
                    }
                    return
                }

                // Same return-to-rest spring as the feed's page cancel (muscle memory).
                withAnimation(reduceMotion ? Motion.reduced : Motion.pageCancel.animation) {
                    dragOffset = .zero
                    basketDragRaw = 0
                }
                guard abs(dy) >= abs(dx) else { return }
                if dy < -swipeThreshold {
                    go(1)
                } else if dy > swipeThreshold {
                    go(-1)
                }
            }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard sessionAssets.indices.contains(next) else {
            Haptics.light()
            return
        }
        withAnimation(reduceMotion ? Motion.reduced : Motion.likedPage) {
            index = next
        }
        Haptics.selection()
    }

    @MainActor
    private func commitBasket(releaseVelocity: CGSize = .zero) async {
        guard !isCommitting, sessionAssets.indices.contains(index) else { return }
        isCommitting = true
        defer { isCommitting = false }

        let asset = sessionAssets[index]
        do {
            _ = try BasketStore(context: modelContext).add(asset: asset)
            Haptics.basket()
        } catch {
            Haptics.warning()
            withAnimation(reduceMotion ? Motion.reduced : Motion.basketCancel) {
                dragOffset = .zero
                basketDragRaw = 0
            }
            return
        }

        // Reduce Motion: no fly; the card simply fades out (index swap below).
        if !reduceMotion {
            let bounds = UIScreen.main.bounds
            // Same as Feed: start at the card's visual center, continue the throw.
            let start = CGPoint(x: bounds.midX + basketDisplayX, y: bounds.midY - 24)
            let thumb = BasketFlyController.quickThumbnail(for: asset)
            basketFly.playFly(
                assetID: asset.localIdentifier,
                startCenter: start,
                image: thumb,
                isVideo: asset.mediaType == .video,
                releaseVelocity: releaseVelocity
            )
        }

        // Ease-out fade where the finger left the card (was ease-in back toward center +
        // fixed sleep); swap on the animation's completion, not a timer.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            withAnimation(reduceMotion ? Motion.reduced : Motion.basketCommit) {
                cardFade = 0
            } completion: {
                done.resume()
            }
        }

        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            sessionAssets.remove(at: index)
            dragOffset = .zero
            basketDragRaw = 0
            cardFade = 1
            if sessionAssets.isEmpty {
                dismiss()
            } else if index >= sessionAssets.count {
                index = sessionAssets.count - 1
            }
        }
        Haptics.prepare()
    }
}
