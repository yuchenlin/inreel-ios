import Photos
import SwiftUI
import UIKit

/// Named coordinate space for basket-tab → fly overlay geometry.
enum BasketChromeSpace {
    static let name = "inreel.basketChrome"
}

struct BasketTabAnchorKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

/// Shared fly-into-basket animation + basket icon frame (MainTabView → Feed / Liked).
@Observable
@MainActor
final class BasketFlyController {
    var basketIconFrame: CGRect = .zero
    var activeFly: FlyItem?
    /// Incremented each time a fly thumb lands in the trash tab — the tab badge pops on it.
    var landingTick = 0

    struct FlyItem: Identifiable, Equatable {
        let id: UUID
        let assetID: String
        let startCenter: CGPoint
        let image: UIImage?
        let isVideo: Bool
        /// Finger velocity at release (pt/s) — the thumb continues the throw.
        let releaseVelocity: CGSize

        static func == (lhs: FlyItem, rhs: FlyItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    func updateBasketFrame(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        basketIconFrame = rect
    }

    /// Kicks a thumbnail fly from `startCenter` (in `BasketChromeSpace`, the card's visual
    /// center at release) toward the trash tab, seeded with the release velocity.
    func playFly(
        assetID: String,
        startCenter: CGPoint,
        image: UIImage?,
        isVideo: Bool,
        releaseVelocity: CGSize = .zero
    ) {
        activeFly = FlyItem(
            id: UUID(),
            assetID: assetID,
            startCenter: startCenter,
            image: image,
            isVideo: isVideo,
            releaseVelocity: releaseVelocity
        )
    }

    func clearFly(id: UUID) {
        if activeFly?.id == id {
            activeFly = nil
        }
    }

    /// The thumb reached the icon (spring settled) — before its fade.
    func flyLanded(id: UUID) {
        if activeFly?.id == id {
            landingTick += 1
        }
    }

    /// Fast local thumb for the fly overlay (never blocks on iCloud).
    static func quickThumbnail(for asset: PHAsset, side: CGFloat = 96) -> UIImage? {
        var image: UIImage?
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let scale = UIScreen.main.scale
        let px = side * scale
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            image = result
        }
        return image
    }

    /// Fallback target when the tab bar is hidden (immersive) or frame not yet measured.
    static func estimatedBasketCenter(in size: CGSize) -> CGPoint {
        // Five equal tabs; basket is index 3. Pill sits near bottom with ~8pt pad.
        let tabCount: CGFloat = 5
        let basketIndex: CGFloat = 3
        let horizontalPad: CGFloat = 18 + 8
        let usable = size.width - horizontalPad * 2
        let cell = usable / tabCount
        let x = horizontalPad + cell * (basketIndex + 0.5)
        let y = size.height - 8 - 26
        return CGPoint(x: x, y: y)
    }
}

/// Full-screen overlay that animates a thumb into the basket tab icon.
struct BasketFlyOverlay: View {
    @Bindable var controller: BasketFlyController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let fly = controller.activeFly {
                    BasketFlyThumb(
                        fly: fly,
                        endCenter: endCenter(in: geo.size),
                        onLanded: { controller.flyLanded(id: fly.id) },
                        onFinished: { controller.clearFly(id: fly.id) }
                    )
                    .id(fly.id)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .allowsHitTesting(false)
        }
    }

    private func endCenter(in size: CGSize) -> CGPoint {
        let frame = controller.basketIconFrame
        if frame.width > 0, frame.height > 0 {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return BasketFlyController.estimatedBasketCenter(in: size)
    }
}

private struct BasketFlyThumb: View {
    let fly: BasketFlyController.FlyItem
    let endCenter: CGPoint
    let onLanded: () -> Void
    let onFinished: () -> Void

    /// Separate x / y progress so the release velocity bends the path into an arc
    /// (a leftward throw keeps travelling left for a beat, then swings into the tab).
    @State private var progressX: CGFloat = 0
    @State private var progressY: CGFloat = 0
    @State private var opacity: CGFloat = 1

    private let startSize: CGFloat = 88
    private let endSize: CGFloat = 22

    var body: some View {
        let center = CGPoint(
            x: fly.startCenter.x + (endCenter.x - fly.startCenter.x) * progressX,
            y: fly.startCenter.y + (endCenter.y - fly.startCenter.y) * progressY
        )
        // Shrink tracks the dominant (vertical) leg so size never overshoots past the icon.
        let t = min(1, max(0, progressY))
        let size = startSize + (endSize - startSize) * t
        let corner = 10 + (4 - 10) * t

        ZStack {
            if let image = fly.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.18)
                Image(systemName: fly.isVideo ? "video.fill" : "photo.fill")
                    .font(.system(size: 22 - 10 * t, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.white.opacity(0.35 * (1 - t)), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45 * (1 - 0.5 * t)), radius: 10 - 6 * t, y: 4)
        .opacity(opacity)
        .position(center)
        .onAppear(perform: launch)
    }

    private func launch() {
        let v = fly.releaseVelocity
        let speed = hypot(v.width, v.height)
        // Fast flick keeps a little overshoot (delight); a slow drag lands flat.
        let bounce = speed >= Motion.flyFastFlickSpeed ? Motion.flyBounceFast : Motion.flyBounceSlow
        let dx = endCenter.x - fly.startCenter.x
        let dy = endCenter.y - fly.startCenter.y
        // Unit-progress initial velocities (pt/s ÷ leg length), clamped so a huge flick
        // can't fling the thumb off screen before the spring brings it home.
        func seed(_ velocity: CGFloat, _ leg: CGFloat) -> Double {
            guard abs(leg) > 1 else { return 0 }
            return Double(min(6, max(-3, velocity / leg)))
        }
        withAnimation(.interpolatingSpring(duration: Motion.flyDuration, bounce: bounce,
                                           initialVelocity: seed(v.width, dx))) {
            progressX = 1
        }
        withAnimation(.interpolatingSpring(duration: Motion.flyDuration, bounce: bounce,
                                           initialVelocity: max(0, seed(v.height, dy)))) {
            progressY = 1
        } completion: {
            // Landed (spring logically complete) → badge pops, quick fade, then free the overlay.
            onLanded()
            withAnimation(Motion.flyFade) {
                opacity = 0
            } completion: {
                onFinished()
            }
        }
    }
}
