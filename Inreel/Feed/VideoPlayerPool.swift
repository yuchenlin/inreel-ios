import AVFoundation
import Foundation
import UIKit

extension Notification.Name {
    /// Posted (synchronously, main actor) when the pool hard-evicts a player; `object` is the
    /// asset localIdentifier. The owning card covers with its poster and re-attaches on demand.
    static let inreelVideoPlayerEvicted = Notification.Name("inreel.videoPlayerEvicted")
}

/// Caps concurrent AVPlayers at 2: the front card + the warmed peek neighbor (the feed only
/// ever mounts two slots; Liked releases the feed's players before acquiring its own).
/// Evicts LRU on acquire — never the active (on-screen, playing) card while another
/// candidate exists — and drops every non-active player on a memory warning.
/// `release` pauses without blanking the current item (avoids a black flash if a layer is
/// still on screen); only hard eviction clears the item, after notifying the owner.
@MainActor
final class VideoPlayerPool {
    static let shared = VideoPlayerPool()

    private let maxPlayers = 2
    private var players: [String: AVPlayer] = [:]
    /// Least-recently-used at index 0.
    private var lru: [String] = []
    /// Ids whose card is the active (front, visible) card — protected from LRU eviction.
    private var activeIDs: Set<String> = []
    private var didConfigureSession = false
    private var memoryObserver: NSObjectProtocol?

    private init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                VideoPlayerPool.shared.evictInactive()
            }
        }
    }

    /// Category `.playback` so unmute is audible even with the hardware silent switch.
    func activatePlaybackSessionIfNeeded() {
        guard !didConfigureSession else {
            // Re-activate in case another app stole the session.
            try? AVAudioSession.sharedInstance().setActive(true)
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            didConfigureSession = true
        } catch {
            // Best-effort — never crash the feed.
        }
    }

    /// Pushes the global `MuteState` onto every pooled player (front card + preloaded peek), so
    /// a neighbor that was warmed before the toggle is already correct when it slides in.
    func applyMuteToAll(_ muted: Bool) {
        for player in players.values {
            applyMute(muted, to: player)
        }
    }

    /// Writes mute UI state onto a live player (and activates playback audio when unmuting).
    func applyMute(_ muted: Bool, to player: AVPlayer) {
        if muted {
            player.isMuted = true
        } else {
            activatePlaybackSessionIfNeeded()
            player.volume = 1.0
            player.isMuted = false
        }
    }

    func acquire(for localIdentifier: String) -> AVPlayer {
        if let existing = players[localIdentifier] {
            touch(localIdentifier)
            return existing
        }
        while players.count >= maxPlayers, let victim = evictionCandidate() {
            evict(victim)
        }
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1.0
        // Born with the global mute state — never a default-unmuted blip on a preloaded card.
        applyMute(MuteState.shared.isMuted, to: player)
        players[localIdentifier] = player
        lru.append(localIdentifier)
        return player
    }

    /// Non-acquiring peek — used by VideoProgressBar to attach a time observer.
    func existingPlayer(for localIdentifier: String) -> AVPlayer? {
        players[localIdentifier]
    }

    /// Pause and drop from the pool. Does **not** `replaceCurrentItem(nil)` — blanking the item
    /// while a layer may still be composited causes a one-frame black flash on swipe settle.
    func release(_ localIdentifier: String) {
        activeIDs.remove(localIdentifier)
        guard let player = players.removeValue(forKey: localIdentifier) else { return }
        lru.removeAll { $0 == localIdentifier }
        player.pause()
    }

    /// The card owning this id became (or stopped being) the active, visible card.
    func setActive(_ localIdentifier: String, _ active: Bool) {
        if active {
            activeIDs.insert(localIdentifier)
        } else {
            activeIDs.remove(localIdentifier)
        }
    }

    /// Memory pressure: keep only the active card's player.
    func evictInactive() {
        for id in lru where !activeIDs.contains(id) {
            evict(id)
        }
    }

    /// Oldest non-active entry; falls back to plain LRU only if everything is active.
    private func evictionCandidate() -> String? {
        lru.first { !activeIDs.contains($0) } ?? lru.first
    }

    /// Hard evict (LRU / memory pressure). The owner hears about it *first* so it can put its
    /// poster back over the layer, then the item is cleared so AVFoundation reclaims buffers.
    private func evict(_ localIdentifier: String) {
        guard let player = players.removeValue(forKey: localIdentifier) else { return }
        lru.removeAll { $0 == localIdentifier }
        activeIDs.remove(localIdentifier)
        player.pause()
        NotificationCenter.default.post(name: .inreelVideoPlayerEvicted, object: localIdentifier)
        player.replaceCurrentItem(with: nil)
    }

    func releaseAll(except keep: String? = nil) {
        for id in Array(players.keys) where id != keep {
            release(id)
        }
    }

    private func touch(_ localIdentifier: String) {
        lru.removeAll { $0 == localIdentifier }
        lru.append(localIdentifier)
    }
}
