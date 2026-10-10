import AVFoundation
import Foundation
import Observation

/// Single source of truth for video sound across the whole app (Feed, Liked viewer, preloaded
/// peek players). Global + persisted:
///
/// - Persisted under `AppSettings.alwaysUnmutedKey` (`true` = sound on). The Settings toggle
///   ("Videos start with sound") and the feed speaker button both write this one value, so
///   **whichever the user changed last wins** — there is no second "default" to reconcile.
/// - Muted stays muted for every subsequent card (next / back / newly loaded) and across
///   relaunch, until the user taps unmute, turns the Settings toggle on, or presses a hardware
///   volume key (`SystemVolumeObserver` → auto-unmute).
/// - Every change is pushed to all pooled `AVPlayer`s; new pool players are created with the
///   current value, so preloaded neighbors are already correct before they appear.
@MainActor
@Observable
final class MuteState {
    static let shared = MuteState()

    /// Current global mute. Read anywhere; write via `setMuted` / `toggle` / `unmuteFromVolumeKey`.
    private(set) var isMuted: Bool

    private let defaults: UserDefaults
    private let appliesToPlayers: Bool
    @ObservationIgnored private var volumeKeyObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - defaults: persistence store (tests pass an isolated suite).
    ///   - appliesToPlayers: false in unit tests so the shared player pool is untouched.
    init(defaults: UserDefaults = .standard, appliesToPlayers: Bool = true) {
        self.defaults = defaults
        self.appliesToPlayers = appliesToPlayers
        // Missing key → product default (muted), same as the pre-55 Settings default.
        let soundOn = (defaults.object(forKey: AppSettings.alwaysUnmutedKey) as? Bool) ?? false
        self.isMuted = !soundOn
    }

    /// Settings-facing view of the same value ("Videos start with sound").
    var soundOn: Bool {
        get { !isMuted }
        set { setMuted(!newValue) }
    }

    func setMuted(_ muted: Bool) {
        // Always persist (cheap) so an external defaults write can never leave us stale.
        defaults.set(!muted, forKey: AppSettings.alwaysUnmutedKey)
        guard muted != isMuted else { return }
        isMuted = muted
        if appliesToPlayers {
            VideoPlayerPool.shared.applyMuteToAll(muted)
        }
    }

    func toggle() {
        setMuted(!isMuted)
    }

    /// Hardware volume up/down. Returns true if this actually unmuted (caller may haptic).
    @discardableResult
    func unmuteFromVolumeKey() -> Bool {
        guard isMuted else { return false }
        setMuted(false)
        return true
    }

    /// Idempotent. Hooks hardware volume keys → global unmute (independent of which card is
    /// on screen, so a muted state never "leaks" past a photo card or a remount).
    func startObservingVolumeKeys() {
        SystemVolumeObserver.shared.start()
        guard volumeKeyObserver == nil else { return }
        volumeKeyObserver = NotificationCenter.default.addObserver(
            forName: .inreelSystemVolumeChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if MuteState.shared.unmuteFromVolumeKey() {
                    Haptics.light()
                }
            }
        }
    }
}
