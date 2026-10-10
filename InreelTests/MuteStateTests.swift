import XCTest
@testable import Inreel

@MainActor
final class MuteStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MuteStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToMutedWhenNothingStored() {
        let state = MuteState(defaults: defaults, appliesToPlayers: false)
        XCTAssertTrue(state.isMuted)
        XCTAssertFalse(state.soundOn)
    }

    func testFeedToggleIsGlobalAndPersistsAcrossRelaunch() {
        defaults.set(true, forKey: AppSettings.alwaysUnmutedKey) // Settings: sound on
        let state = MuteState(defaults: defaults, appliesToPlayers: false)
        XCTAssertFalse(state.isMuted)

        state.toggle() // feed speaker → mute
        XCTAssertTrue(state.isMuted)
        XCTAssertEqual(defaults.object(forKey: AppSettings.alwaysUnmutedKey) as? Bool, false)

        // "Relaunch": a fresh instance reads the last user choice, not the old Settings value.
        let relaunched = MuteState(defaults: defaults, appliesToPlayers: false)
        XCTAssertTrue(relaunched.isMuted)
    }

    func testSettingsAndFeedShareOneValueLastWriteWins() {
        let state = MuteState(defaults: defaults, appliesToPlayers: false)
        state.soundOn = true // Settings toggle ON
        XCTAssertFalse(state.isMuted)
        state.setMuted(true) // feed mute
        XCTAssertFalse(state.soundOn) // Settings toggle reflects it
        state.soundOn = true // Settings again
        XCTAssertFalse(state.isMuted)
    }

    func testVolumeKeyUnmutesOnlyWhenMuted() {
        let state = MuteState(defaults: defaults, appliesToPlayers: false)
        XCTAssertTrue(state.unmuteFromVolumeKey())
        XCTAssertFalse(state.isMuted)
        XCTAssertEqual(defaults.object(forKey: AppSettings.alwaysUnmutedKey) as? Bool, true)
        XCTAssertFalse(state.unmuteFromVolumeKey()) // already unmuted → no-op
    }
}
