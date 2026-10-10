import AVFoundation
import Foundation
import UIKit

extension Notification.Name {
    /// Posted on the main queue when a hardware volume key changes `AVAudioSession.outputVolume`
    /// while the app is active (route changes / session re-activation are filtered out).
    static let inreelSystemVolumeChanged = Notification.Name("inreelSystemVolumeChanged")
}

/// KVO on `AVAudioSession.sharedInstance().outputVolume` so volume buttons can unmute the feed
/// (TikTok / Reels-style). System volume still changes normally and the system HUD still shows —
/// we only observe, and never write the system volume ourselves (so there are no programmatic
/// changes to mistake for key presses).
///
/// Robustness:
/// - KVO only fires while our session is active → (re)activate on start and on every
///   `didBecomeActive` / interruption-end, then re-baseline without posting.
/// - Headphone / Bluetooth route changes also move `outputVolume` → ignored for a short window
///   after `routeChangeNotification` (and the baseline is refreshed).
/// - Changes while the app is not `.active` (Control Center slider, background) are ignored.
/// - Known OS limit: at 100% (or 0%) a further up (or down) press does not change `outputVolume`
///   and so cannot be observed without private API; the opposite key still works.
@MainActor
final class SystemVolumeObserver {
    static let shared = SystemVolumeObserver()

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float?
    /// Ignore volume deltas until this time (route change / re-activation settling).
    private var suppressUntil: Date = .distantPast
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Short confirmation delay so a route-change notification that lands just *after* its
    /// KVO volume jump can still cancel it (headphones unplugged ≠ volume key).
    private var pendingPost: Task<Void, Never>?

    private static let settleWindow: TimeInterval = 0.6
    private static let confirmDelay: UInt64 = 150_000_000

    private init() {}

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Session is usually already `.playback` from InreelApp / VideoPlayerPool; re-activate for KVO.
        try? session.setActive(true)
        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { session, _ in
            let newVolume = session.outputVolume
            Task { @MainActor in
                SystemVolumeObserver.shared.handleVolume(newVolume)
            }
        }
        installLifecycleObservers()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        lastVolume = nil
        pendingPost?.cancel()
        pendingPost = nil
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        lifecycleObservers.removeAll()
    }

    private func handleVolume(_ newVolume: Float) {
        let previous = lastVolume
        lastVolume = newVolume
        guard let previous, abs(previous - newVolume) > 0.0001 else { return }
        guard Date() >= suppressUntil else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        pendingPost?.cancel()
        pendingPost = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.confirmDelay)
            guard !Task.isCancelled else { return }
            let observer = SystemVolumeObserver.shared
            guard Date() >= observer.suppressUntil,
                  UIApplication.shared.applicationState == .active else { return }
            NotificationCenter.default.post(name: .inreelSystemVolumeChanged, object: nil)
        }
    }

    /// Re-activate + re-baseline without treating the jump as a key press.
    private func rebaseline(reactivate: Bool) {
        pendingPost?.cancel()
        pendingPost = nil
        let session = AVAudioSession.sharedInstance()
        if reactivate {
            try? session.setActive(true)
        }
        suppressUntil = Date().addingTimeInterval(Self.settleWindow)
        lastVolume = session.outputVolume
    }

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SystemVolumeObserver.shared.rebaseline(reactivate: true) }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SystemVolumeObserver.shared.rebaseline(reactivate: false) }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = typeRaw == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated {
                SystemVolumeObserver.shared.rebaseline(reactivate: ended)
            }
        })
    }
}
