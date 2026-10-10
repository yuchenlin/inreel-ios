import QuartzCore
import UIKit

/// Frame-driven, interruptible 1-D spring (UIViewPropertyAnimator-style) for the feed's
/// vertical page settle.
///
/// SwiftUI `withAnimation` cannot report a presentation value, so a settle could not be
/// caught mid-flight (the feed locked input for ~260ms). This driver owns the value: every
/// display frame it integrates a damped spring and hands the position to `onUpdate`, so a
/// new touch can `stop()` it, read the exact on-screen value, and resume follow-finger.
///
/// Parametrized like SwiftUI springs (response / dampingFraction, unit mass).
@MainActor
final class SpringDriver {
    private(set) var value: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat = 0
    private(set) var origin: CGFloat = 0

    private var stiffness: CGFloat = 0
    private var damping: CGFloat = 0
    private var clampOvershoot = true
    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var onUpdate: ((CGFloat) -> Void)?
    private var onComplete: (() -> Void)?

    /// Rest thresholds: sub-half-pixel and visually still.
    private let restDistance: CGFloat = 0.5
    private let restVelocity: CGFloat = 12
    /// Hard stop so a pathological spring can never hold the feed hostage.
    private let maxDuration: CFTimeInterval = 1.2

    var isRunning: Bool { link != nil }

    /// Fraction of the way from `origin` to `target` (0…1), for interrupt gating.
    var progress: CGFloat {
        let span = target - origin
        guard abs(span) > 0.001 else { return 1 }
        return min(1, max(0, (value - origin) / span))
    }

    /// - Parameters:
    ///   - initialVelocity: pt/s in the same axis as `value` (e.g. DragGesture velocity).
    ///   - clampOvershoot: never travel past `target` (feed: avoids revealing black behind
    ///     the neighbor); the spring simply lands when it reaches the target.
    func animate(
        from start: CGFloat,
        to end: CGFloat,
        initialVelocity: CGFloat,
        response: Double,
        dampingFraction: Double,
        clampOvershoot: Bool = true,
        onUpdate: @escaping (CGFloat) -> Void,
        onComplete: @escaping () -> Void
    ) {
        stopLink()
        value = start
        origin = start
        target = end
        velocity = initialVelocity
        let omega = 2 * Double.pi / max(0.01, response)
        stiffness = CGFloat(omega * omega)
        damping = CGFloat(2 * dampingFraction * omega)
        self.clampOvershoot = clampOvershoot
        self.onUpdate = onUpdate
        self.onComplete = onComplete
        elapsed = 0
        lastTimestamp = 0

        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
    }

    /// Cancels the settle without completing. Returns the current on-screen value.
    @discardableResult
    func stop() -> CGFloat {
        stopLink()
        onUpdate = nil
        onComplete = nil
        return value
    }

    fileprivate func step(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        if lastTimestamp == 0 {
            lastTimestamp = timestamp
        }
        // Integrate up to the frame that is about to be shown.
        var dt = max(0, targetTimestamp - lastTimestamp)
        lastTimestamp = targetTimestamp
        dt = min(dt, 1.0 / 30.0)
        elapsed += dt

        // Semi-implicit Euler with fixed sub-steps (stable for stiff springs).
        let subSteps = max(1, Int((dt / (1.0 / 480.0)).rounded(.up)))
        let h = CGFloat(dt) / CGFloat(subSteps)
        var landed = false
        for _ in 0..<subSteps {
            let displacement = value - target
            let accel = -stiffness * displacement - damping * velocity
            velocity += accel * h
            value += velocity * h
            if clampOvershoot {
                let crossed = (origin <= target) ? (value >= target) : (value <= target)
                if crossed {
                    value = target
                    velocity = 0
                    landed = true
                    break
                }
            }
        }

        let atRest = abs(value - target) < restDistance && abs(velocity) < restVelocity
        if landed || atRest || elapsed >= maxDuration {
            value = target
            velocity = 0
            let update = onUpdate
            let complete = onComplete
            stopLink()
            onUpdate = nil
            onComplete = nil
            update?(value)
            complete?()
            return
        }
        onUpdate?(value)
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        proxy = nil
    }
}

/// Breaks the CADisplayLink → target retain cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: SpringDriver?

    init(owner: SpringDriver) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        owner?.step(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
    }
}
