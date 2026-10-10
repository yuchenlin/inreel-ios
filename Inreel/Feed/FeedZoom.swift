import SwiftUI
import UIKit
import os.log

private let zoomLog = Logger(subsystem: "app.inreel.ios", category: "FeedZoom")

private enum FeedZoomMetrics {
    static let zoomEpsilon: CGFloat = 1.02
    static let maxScale: CGFloat = 4
}

private struct FeedZoomLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the current feed card is pinch-zoomed (or a pinch is in progress).
    /// Tall-photo scrolling turns off so pan moves the zoomed image instead.
    var feedZoomLocked: Bool {
        get { self[FeedZoomLockedKey.self] }
        set { self[FeedZoomLockedKey.self] = newValue }
    }
}

/// Pinch-zoom / pan for the feed media only (photo and video). Chrome stays put.
/// At scale ≈ 1 the pan recognizer does not begin, so feed swipes still win.
///
/// UIKit container owns the SwiftUI media (UIHostingController) and the pinch/pan
/// recognizers on the same hit-tested view. Builds 27–28 attached UIPinch to a
/// bridge sibling (background/overlay) off the hit-test path, so pinch never began.
struct ZoomableFeedMedia<Content: View>: View {
    var resetID: String
    @Binding var isZoomed: Bool
    /// Bump to animate back to 1x (double-tap while zoomed).
    var resetTick: Int
    /// When true, center long-press drives 2× video via `onSpeedBoostChanged`.
    var speedBoostEnabled: Bool = false
    var onSpeedBoostChanged: ((Bool) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZoomHostRepresentable(
            resetID: resetID,
            resetTick: resetTick,
            isZoomed: $isZoomed,
            speedBoostEnabled: speedBoostEnabled,
            onSpeedBoostChanged: onSpeedBoostChanged,
            content: content()
        )
    }
}

// MARK: - UIKit host

private struct ZoomHostRepresentable<Content: View>: UIViewRepresentable {
    var resetID: String
    var resetTick: Int
    @Binding var isZoomed: Bool
    var speedBoostEnabled: Bool
    var onSpeedBoostChanged: ((Bool) -> Void)?
    var content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    func makeUIView(context: Context) -> ZoomHostView {
        let view = ZoomHostView()
        view.accessibilityIdentifier = "feed.zoom.host"
        view.onLayout = { [weak coordinator = context.coordinator] host in
            coordinator?.hostDidLayout(host)
        }
        context.coordinator.install(on: view)
        context.coordinator.speedBoostEnabled = speedBoostEnabled
        context.coordinator.onSpeedBoostChanged = onSpeedBoostChanged
        context.coordinator.setContent(content, zoomed: isZoomed, in: view)
        return view
    }

    func updateUIView(_ uiView: ZoomHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isZoomed = $isZoomed
        coordinator.speedBoostEnabled = speedBoostEnabled
        coordinator.onSpeedBoostChanged = onSpeedBoostChanged
        uiView.onLayout = { [weak coordinator] host in
            coordinator?.hostDidLayout(host)
        }
        coordinator.setContent(content, zoomed: isZoomed || coordinator.currentScale > FeedZoomMetrics.zoomEpsilon, in: uiView)

        if coordinator.resetID != resetID {
            let hadID = coordinator.resetID != nil
            coordinator.resetID = resetID
            if hadID {
                coordinator.reset(animated: false)
            }
        }
        if coordinator.resetTick != resetTick {
            let previous = coordinator.resetTick
            coordinator.resetTick = resetTick
            if previous != nil {
                coordinator.reset(animated: true)
            }
        }
        coordinator.doubleTap.isEnabled =
            coordinator.currentScale > FeedZoomMetrics.zoomEpsilon || isZoomed
        coordinator.longPress.isEnabled = speedBoostEnabled
        coordinator.publishAccessibility(on: uiView)
    }

    static func dismantleUIView(_ uiView: ZoomHostView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class ZoomHostView: UIView {
        var onLayout: ((ZoomHostView) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            clipsToBounds = true
            isMultipleTouchEnabled = true
            isUserInteractionEnabled = true
            isAccessibilityElement = true
            accessibilityLabel = "Feed media"
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        var resetID: String?
        var resetTick: Int?
        var speedBoostEnabled = false
        var onSpeedBoostChanged: ((Bool) -> Void)?

        private(set) var currentScale: CGFloat = 1
        private var currentOffset: CGSize = .zero
        private var pinching = false
        private var pinchStartScale: CGFloat = 1
        private var pinchStartOffset: CGSize = .zero
        private var pinchStartLocation: CGPoint = .zero
        private var panStartOffset: CGSize = .zero
        private var speedBoostActive = false

        private weak var hostView: ZoomHostView?
        private weak var contentContainer: UIView?
        private var hostingController: UIHostingController<AnyView>?
        /// Tracks last `feedZoomLocked` pushed into hosted SwiftUI.
        private var hostedZoomLocked = false

        let pinch = UIPinchGestureRecognizer()
        let pan = UIPanGestureRecognizer()
        let doubleTap = UITapGestureRecognizer()
        let longPress = UILongPressGestureRecognizer()

        init(isZoomed: Binding<Bool>) {
            self.isZoomed = isZoomed
            super.init()
            pinch.addTarget(self, action: #selector(handlePinch(_:)))
            pan.addTarget(self, action: #selector(handlePan(_:)))
            doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
            longPress.addTarget(self, action: #selector(handleSpeedBoost(_:)))
            pinch.cancelsTouchesInView = false
            pinch.delaysTouchesBegan = false
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 2
            doubleTap.numberOfTapsRequired = 2
            doubleTap.cancelsTouchesInView = false
            doubleTap.delaysTouchesBegan = false
            doubleTap.isEnabled = false
            // Hold still ~0.35s; small jitter OK. Feed drag uses minDistance 16.
            longPress.minimumPressDuration = 0.35
            longPress.allowableMovement = 14
            longPress.cancelsTouchesInView = false
            longPress.delaysTouchesBegan = false
            longPress.isEnabled = false
            pinch.delegate = self
            pan.delegate = self
            doubleTap.delegate = self
            longPress.delegate = self
        }

        func install(on host: ZoomHostView) {
            hostView = host
            if pinch.view !== host {
                host.addGestureRecognizer(pinch)
                host.addGestureRecognizer(pan)
                host.addGestureRecognizer(doubleTap)
                host.addGestureRecognizer(longPress)
            }
            host.isMultipleTouchEnabled = true
            NSLog("INREEL_ZOOM attach host=%@ bounds=%@", String(describing: type(of: host)), NSCoder.string(for: host.bounds))
            zoomLog.info("attach")
        }

        func hostDidLayout(_ host: ZoomHostView) {
            layoutContent(in: host)
        }

        @MainActor
        func setContent(_ content: Content, zoomed: Bool, in host: ZoomHostView) {
            // Separate UIHostingController = separate environment chain → forward globals explicitly.
            let wrapped = AnyView(
                content
                    .environment(\.feedZoomLocked, zoomed)
                    .environment(MuteState.shared)
            )
            hostedZoomLocked = zoomed

            if let hostingController {
                hostingController.rootView = wrapped
                layoutContent(in: host)
                return
            }

            let container = UIView(frame: host.bounds)
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = true
            container.isMultipleTouchEnabled = true
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(container)
            contentContainer = container

            let hosting = UIHostingController(rootView: wrapped)
            hosting.view.backgroundColor = .clear
            hosting.view.isOpaque = false
            hosting.safelyDisableSafeAreaInsets()
            hosting.view.frame = container.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(hosting.view)
            hostingController = hosting

            layoutContent(in: host)
            applyTransform()
            NSLog("INREEL_ZOOM embedded hosting in host bounds=%@", NSCoder.string(for: host.bounds))
        }

        private func refreshZoomEnvironment() {
            guard let hosting = hostingController else { return }
            let locked = currentScale > FeedZoomMetrics.zoomEpsilon || pinching || isZoomed.wrappedValue
            guard locked != hostedZoomLocked else { return }
            hostedZoomLocked = locked
            // Re-wrap current root is awkward without stored Content; updateUIView
            // refreshes content frequently. Force a no-op root touch via isZoomed binding
            // which triggers SwiftUI update cycle in the parent.
            _ = hosting
        }

        private func layoutContent(in host: ZoomHostView) {
            guard let container = contentContainer else { return }
            let bounds = host.bounds
            guard bounds.width > 1, bounds.height > 1 else { return }

            // Reset transform to set frames in untransformed space, then reapply.
            let saved = container.transform
            container.transform = .identity
            container.bounds = CGRect(origin: .zero, size: bounds.size)
            container.center = CGPoint(x: bounds.midX, y: bounds.midY)
            container.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            if let hosted = hostingController?.view {
                hosted.frame = container.bounds
            }
            container.transform = saved == .identity ? transformForCurrentState() : saved
            if saved == .identity {
                applyTransform()
            }
        }

        func teardown() {
            if speedBoostActive {
                speedBoostActive = false
                onSpeedBoostChanged?(false)
            }
            pinch.view?.removeGestureRecognizer(pinch)
            pan.view?.removeGestureRecognizer(pan)
            doubleTap.view?.removeGestureRecognizer(doubleTap)
            longPress.view?.removeGestureRecognizer(longPress)
            hostingController?.view.removeFromSuperview()
            hostingController = nil
            contentContainer?.removeFromSuperview()
            contentContainer = nil
            hostView = nil
        }

        @objc private func handleSpeedBoost(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard speedBoostEnabled else { return }
                guard currentScale <= FeedZoomMetrics.zoomEpsilon, !isZoomed.wrappedValue else { return }
                guard !VideoScrubGate.isScrubbing else { return }
                guard let host = hostView else { return }
                let point = gesture.location(in: host)
                guard Self.isInSpeedBoostZone(point, bounds: host.bounds) else { return }
                speedBoostActive = true
                onSpeedBoostChanged?(true)
                NSLog("INREEL_SPEED boost.began")
            case .ended, .cancelled, .failed:
                guard speedBoostActive else { return }
                speedBoostActive = false
                onSpeedBoostChanged?(false)
                NSLog("INREEL_SPEED boost.ended state=%ld", gesture.state.rawValue)
            default:
                break
            }
        }

        /// Center band — skip edges (paging/basket) and bottom scrub/chrome.
        private static func isInSpeedBoostZone(_ point: CGPoint, bounds: CGRect) -> Bool {
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let marginX = bounds.width * 0.12
            let marginY = bounds.height * 0.12
            let bottomExclude: CGFloat = 100
            return point.x >= bounds.minX + marginX
                && point.x <= bounds.maxX - marginX
                && point.y >= bounds.minY + marginY
                && point.y <= bounds.maxY - marginY - bottomExclude
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let host = hostView else { return }
            layoutContent(in: host)

            switch gesture.state {
            case .began:
                pinching = true
                pinchStartScale = currentScale
                pinchStartOffset = currentOffset
                pinchStartLocation = gesture.location(in: host)
                publish(scale: currentScale, offset: currentOffset, zooming: true, animated: false)
                NSLog("INREEL_ZOOM pinch.began scale=%.3f", currentScale)
            case .changed:
                let raw = pinchStartScale * gesture.scale
                let next = min(FeedZoomMetrics.maxScale, max(1, raw))
                let location = gesture.location(in: host)
                let shifted = anchoredOffset(
                    startScale: pinchStartScale,
                    startOffset: pinchStartOffset,
                    newScale: next,
                    startLocation: pinchStartLocation,
                    location: location,
                    in: host.bounds.size
                )
                publish(scale: next, offset: shifted, zooming: true, animated: false)
                if Int(next * 10) != Int(currentScale * 10) {
                    NSLog("INREEL_ZOOM pinch.changed scale=%.3f", next)
                }
            case .ended, .cancelled, .failed:
                pinching = false
                NSLog("INREEL_ZOOM pinch.ended scale=%.3f", currentScale)
                settle()
            default:
                break
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !pinching, currentScale > FeedZoomMetrics.zoomEpsilon, let host = hostView else { return }
            switch gesture.state {
            case .began:
                panStartOffset = currentOffset
            case .changed:
                let translation = gesture.translation(in: host)
                let next = CGSize(
                    width: panStartOffset.width + translation.x,
                    height: panStartOffset.height + translation.y
                )
                publish(
                    scale: currentScale,
                    offset: clamp(next, scale: currentScale, in: host.bounds.size),
                    zooming: true,
                    animated: false
                )
            default:
                break
            }
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard currentScale > FeedZoomMetrics.zoomEpsilon else { return }
            reset(animated: true)
        }

        private func settle() {
            let current = currentScale
            guard let host = hostView else {
                publish(scale: 1, offset: .zero, zooming: false, animated: true)
                return
            }
            if current <= FeedZoomMetrics.zoomEpsilon {
                reset(animated: true)
                return
            }
            let clampedScale = min(FeedZoomMetrics.maxScale, max(1, current))
            let clampedOffset = clamp(currentOffset, scale: clampedScale, in: host.bounds.size)
            publish(scale: clampedScale, offset: clampedOffset, zooming: true, animated: true)
        }

        func reset(animated: Bool) {
            pinching = false
            publish(scale: 1, offset: .zero, zooming: false, animated: animated)
        }

        private func publish(scale: CGFloat, offset: CGSize, zooming: Bool, animated: Bool) {
            currentScale = scale
            currentOffset = offset
            let zoomLocked = zooming || scale > FeedZoomMetrics.zoomEpsilon
            doubleTap.isEnabled = scale > FeedZoomMetrics.zoomEpsilon

            let apply = { [weak self] in
                guard let self else { return }
                self.applyTransform()
            }

            if animated {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0.2,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                    animations: apply,
                    completion: { [weak self] _ in
                        self?.isZoomed.wrappedValue = zoomLocked
                        if let host = self?.hostView {
                            self?.publishAccessibility(on: host)
                        }
                    }
                )
            } else {
                apply()
                isZoomed.wrappedValue = zoomLocked
                if let host = hostView {
                    publishAccessibility(on: host)
                }
            }
            refreshZoomEnvironment()
        }

        private func transformForCurrentState() -> CGAffineTransform {
            CGAffineTransform.identity
                .translatedBy(x: currentOffset.width, y: currentOffset.height)
                .scaledBy(x: currentScale, y: currentScale)
        }

        private func applyTransform() {
            contentContainer?.transform = transformForCurrentState()
        }

        func publishAccessibility(on host: ZoomHostView) {
            host.accessibilityValue = String(format: "scale %.2f", currentScale)
        }

        private func anchoredOffset(
            startScale: CGFloat,
            startOffset: CGSize,
            newScale: CGFloat,
            startLocation: CGPoint,
            location: CGPoint,
            in size: CGSize
        ) -> CGSize {
            let p0 = CGPoint(x: startLocation.x - size.width / 2, y: startLocation.y - size.height / 2)
            let p1 = CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
            let s0 = max(startScale, 0.001)
            let contentX = (p0.x - startOffset.width) / s0
            let contentY = (p0.y - startOffset.height) / s0
            let raw = CGSize(
                width: p1.x - contentX * newScale,
                height: p1.y - contentY * newScale
            )
            return clamp(raw, scale: newScale, in: size)
        }

        private func clamp(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
            let maxX = max(0, (size.width * (scale - 1)) / 2)
            let maxY = max(0, (size.height * (scale - 1)) / 2)
            return CGSize(
                width: min(maxX, max(-maxX, offset.width)),
                height: min(maxY, max(-maxY, offset.height))
            )
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === pan {
                return !pinching && currentScale > FeedZoomMetrics.zoomEpsilon
            }
            if gestureRecognizer === doubleTap {
                return currentScale > FeedZoomMetrics.zoomEpsilon
            }
            if gestureRecognizer === longPress {
                guard speedBoostEnabled else { return false }
                guard currentScale <= FeedZoomMetrics.zoomEpsilon, !isZoomed.wrappedValue else { return false }
                guard !VideoScrubGate.isScrubbing else { return false }
                guard let host = hostView else { return false }
                return Self.isInSpeedBoostZone(gestureRecognizer.location(in: host), bounds: host.bounds)
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === pinch || other === pinch {
                return true
            }
            // Long-press must win over feed paging while holding still; still allow
            // simultaneous until it fires so a real swipe can cancel via allowableMovement.
            if gestureRecognizer === longPress || other === longPress {
                return true
            }
            if currentScale <= FeedZoomMetrics.zoomEpsilon && !pinching {
                return true
            }
            if gestureRecognizer === pan, other is UIPanGestureRecognizer {
                return false
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let host = hostView else { return false }
            return host.bounds.contains(touch.location(in: host))
        }
    }
}

private extension UIHostingController {
    func safelyDisableSafeAreaInsets() {
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
        view.insetsLayoutMarginsFromSafeArea = false
    }
}
