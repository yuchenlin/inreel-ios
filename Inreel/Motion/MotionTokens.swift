import SwiftUI
import UIKit

/// Single source of truth for Inreel motion. Every spring / duration used by Feed, Liked,
/// Basket, tabs and chrome lives here so the product feels like one hand tuned it.
///
/// Rules of thumb (Apple fluid interfaces + Emil Kowalski):
/// - Gesture release → spring (velocity-aware, interruptible). Light bounce only where the
///   user threw something (fly-to-trash, heart). Chrome stays critically damped-ish (≥0.88).
/// - Enter / exit of UI → ease-out (fast start, the moment the eye is watching). Never ease-in.
/// - Reduce Motion → drop travel / scale; keep ≤150ms opacity so state is still communicated.
enum Motion {

    // MARK: - Vertical feed paging

    /// Spring used by `SpringDriver` to settle a committed page to ±pageExtent.
    /// response 0.30s / damping 0.88 ≈ the old interactiveSpring(0.28, 0.88) feel, but driven
    /// frame-by-frame so a new touch can catch it mid-flight. Finger velocity seeds the spring.
    static let pageSettle = SpringSpec(response: 0.30, dampingFraction: 0.88)
    /// Cap on the release velocity handed to the settle spring (pt/s) so a violent flick
    /// cannot overshoot past the neighbor and reveal black behind it.
    static let pageMaxHandoffVelocity: CGFloat = 4_000
    /// A settle may be caught by a new touch only while |stackY| < 85% of the page height;
    /// past that the dual-slot promote is a few frames away and we let it land.
    static let pageInterruptFraction: CGFloat = 0.85

    /// Release without commit (didn't cross threshold) → back to rest, snappy, tiny bounce.
    static let pageCancel = SpringSpec(response: 0.28, dampingFraction: 0.86)

    /// Release while rubber-banding past the first/last item → back to rest, no bounce, so the
    /// "end of feed" reads as a firm wall (matches UIScrollView edge bounce-back).
    static let edgeRelease = SpringSpec(response: 0.32, dampingFraction: 0.90)
    /// UIScrollView-style rubber-band constant: offset = (1 - 1/(x·c/d + 1)) · d.
    /// 0.55 is Apple's constant; at 100pt finger travel the card moves ~50pt, at 300pt ~140pt.
    static let edgeRubberBandConstant: CGFloat = 0.55

    /// Reduce Motion page change: crossfade old → new in place (no vertical travel).
    static let pageCrossfade = Animation.easeOut(duration: 0.14)
    /// Reduce Motion return-to-rest after a drag: short and critically damped (no bounce).
    static let reducedSettle = SpringSpec(response: 0.18, dampingFraction: 1.0)

    // MARK: - Left-swipe → basket

    /// Basket swipe released short of threshold → card springs home (slight life, not jelly).
    static let basketCancel = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Committed basket swipe: departing card collapses back while the thumb flies.
    /// Ease-OUT so the handoff starts instantly (ease-in made the card hesitate).
    static let basketCommit = Animation.easeOut(duration: 0.16)
    /// Same commit timing as a sleep budget for the promote swap (just before collapse ends).
    static let basketCommitSwapDelay: UInt64 = 120_000_000
    /// Fallback path (no warmed neighbor): new card slides in a short distance from the right.
    static let basketSlideIn = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Wait before showing Undo on the slide-in fallback (lets the slide mostly settle first).
    static let basketSlideInSettle: UInt64 = 160_000_000
    /// Reduce Motion basket: crossfade length before the promote swap (matches `reduced`).
    static let reducedSwapDelay: UInt64 = 150_000_000
    /// Threshold "armed" pop on the trash affordance behind the card.
    static let basketArm = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.86)
    /// Rubber-band factor past the basket threshold (display only; thresholds use raw drag).
    static let basketOverdragResistance: CGFloat = 0.35

    // MARK: - Fly-to-trash

    /// Perceptual duration of the thumb's flight into the trash tab.
    static let flyDuration: Double = 0.36
    /// Bounce for a fast flick (keeps a touch of overshoot = "thrown") vs a slow drag (settles).
    static let flyBounceFast: Double = 0.16   // ≈ dampingFraction 0.84
    static let flyBounceSlow: Double = 0.10   // ≈ dampingFraction 0.90
    /// Release speed (pt/s) above which a basket swipe counts as a "flick".
    static let flyFastFlickSpeed: CGFloat = 900
    /// Thumb fades once it has landed in the icon.
    static let flyFade = Animation.easeOut(duration: 0.12)

    /// Basket tab badge pop when the thumb lands (spatial continuity with the fly).
    static let badgeBump = Animation.spring(response: 0.28, dampingFraction: 0.85)
    /// Peak scale of that pop (1 → 1.08 → 1).
    static let badgeBumpScale: CGFloat = 1.08

    // MARK: - Undo capsule

    /// Undo chip rises a few points into place, attached to the action that spawned it.
    static let undoPresent = Animation.spring(response: 0.30, dampingFraction: 0.90)
    /// Undo chip leaves (tap or timeout).
    static let undoDismiss = Animation.easeOut(duration: 0.18)
    /// How long the chip stays before auto-hiding.
    static let undoDwell: UInt64 = 2_200_000_000
    /// Vertical travel of the chip on enter (small = attached, not a flying alert).
    static let undoRise: CGFloat = 14

    // MARK: - Like

    /// Heart icon fill/scale toggle. Damping 0.72: a pop, not a wobble (was 0.6).
    static let likeToggle = Animation.spring(response: 0.26, dampingFraction: 0.72)
    /// Double-tap heart burst enter: from 0.92 scale, delight without jelly.
    static let heartBurstIn = Animation.spring(response: 0.26, dampingFraction: 0.78)
    /// Burst's starting scale (0.92 ≈ "pops from the icon", vs 0.4 "from nothing").
    static let heartBurstStartScale: CGFloat = 0.92
    /// Heart burst exit.
    static let heartBurstOut = Animation.easeOut(duration: 0.18)
    /// Hold before exit so total visible time stays ≲350ms (rapid likes don't stack motion).
    static let heartBurstHold: UInt64 = 170_000_000
    /// Favorite write failed → heart shakes back to its old state (linear, total seconds).
    static let favoriteRollbackShake: Double = 0.36
    /// Peak horizontal travel of that shake (pt). Reduce Motion → 0 (amber ring flash only).
    static let favoriteRollbackShakeTravel: CGFloat = 6
    /// Amber ring that flags the rollback fades out over this.
    static let favoriteRollbackFlashOut = Animation.easeOut(duration: 0.45)

    // MARK: - Press feedback

    /// Finger-down on a floating action: quick ease-out squish.
    static let press = Animation.easeOut(duration: 0.11)
    /// Finger-up: spring back (asymmetric press vs release feels physical).
    static let release = Animation.spring(response: 0.26, dampingFraction: 0.80)
    /// Pressed scale of floating actions (3% squish: felt, not seen).
    static let pressScale: CGFloat = 0.97

    // MARK: - Tabs & chrome

    /// Floating tab selection — single animation owner. 0.92 damping: no bounce on a
    /// high-frequency tap.
    static let tabSelect = Animation.spring(response: 0.28, dampingFraction: 0.92)
    /// Tab bar / immersive chrome show & hide.
    static let chrome = Animation.easeOut(duration: 0.22)
    /// Small chrome toggles (photo meta tap-to-hide, cloud download chip).
    static let chromeFast = Animation.easeOut(duration: 0.15)
    /// iCloud-downloading blur on a photo clears/applies (overlay only, never layout).
    static let cloudBlur = Animation.easeOut(duration: 0.18)

    // MARK: - Lists, toasts, onboarding

    /// Toast enter / exit (Basket "deleted" / "emptied").
    static let toast = Animation.easeOut(duration: 0.20)
    /// Toast dwell before auto-hide.
    static let toastDwell: UInt64 = 2_400_000_000
    /// Basket grid row insert / remove reflow.
    static let listReflow = Animation.spring(response: 0.32, dampingFraction: 0.90)
    /// Onboarding page change (rare; slightly softer, still no bounce).
    static let onboardingPage = Animation.spring(response: 0.35, dampingFraction: 0.92)
    /// Liked viewer page step (index swap crossfade).
    static let likedPage = Animation.easeOut(duration: 0.20)

    // MARK: - Video scrub

    /// Scrub bar thicken / time labels on grab.
    static let scrubChrome = Animation.easeOut(duration: 0.12)
    /// Release within this fraction of either end snaps to the end (no "stuck at 99%").
    static let scrubEdgeSnapFraction: Double = 0.02
    /// The fill's short ease-out to 0 / 1 on that snap (the drag itself stays 1:1).
    static let scrubEdgeSnap = Animation.easeOut(duration: 0.12)

    // MARK: - Reduce Motion

    /// Generic Reduce Motion replacement: opacity / color only, ≤150ms.
    static let reduced = Animation.easeOut(duration: 0.15)
    /// Reduce Motion heart toggle: critically damped, short.
    static let reducedLikeToggle = Animation.spring(response: 0.20, dampingFraction: 1.0)

    /// Picks the Reduce Motion substitute when the user asked for less motion.
    static func choose(_ full: Animation, reduceMotion: Bool, reduced: Animation = Motion.reduced) -> Animation {
        reduceMotion ? reduced : full
    }

    /// Process-wide Reduce Motion flag for non-View code (controllers, overlays).
    @MainActor static var prefersReducedMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}

/// response / dampingFraction pair usable both by SwiftUI and the frame-driven `SpringDriver`.
struct SpringSpec: Sendable {
    /// Perceptual period (s): lower = snappier.
    let response: Double
    /// 1.0 = critically damped (no overshoot); lower = more bounce.
    let dampingFraction: Double

    var animation: Animation {
        .spring(response: response, dampingFraction: dampingFraction)
    }
}
