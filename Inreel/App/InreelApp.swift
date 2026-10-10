import SwiftUI
import SwiftData
import UIKit
import AVFoundation

@main
struct InreelApp: App {
    init() {
        AppSettings.migrateFeedFilterIfNeeded()
        // Black window from process start — kills the ~1s white flash under launch → first frame.
        UIWindow.appearance().backgroundColor = .black
        // Playback session so video unmute is audible (silent switch / default ambient otherwise).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // Best-effort at launch.
        }
        // Observe hardware volume so global mute auto-unmutes on a volume key (TikTok-style).
        MuteState.shared.startObservingVolumeKeys()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background(Theme.background.ignoresSafeArea())
                // Single source of truth for video sound (Feed, Liked viewer, Settings).
                .environment(MuteState.shared)
        }
        .modelContainer(for: [SeenRecord.self, Note.self, BasketItem.self, Stats.self])
    }
}
