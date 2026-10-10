import XCTest
@testable import Inreel

@MainActor
final class FeedRestoreTests: XCTestCase {
    func testUndoAfterBasketLandsOnRestoredItem() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C"], historyIndex: 1) // on B
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        XCTAssertEqual(s.advance(), "C")
        XCTAssertEqual(s.currentIdentifier, "C")
        XCTAssertTrue(s.debugBasketIdentifiers.contains("B"))
        // History keeps ghost B
        XCTAssertEqual(s.debugHistory, ["A", "B", "C"])

        let landed = s.restoreBasketed(
            "B",
            previousNeighborID: "A",
            nextNeighborID: "C",
            seekIfNear: true
        )
        XCTAssertTrue(landed)
        XCTAssertEqual(s.currentIdentifier, "B")
        XCTAssertEqual(s.debugHistory, ["A", "B", "C"])
        XCTAssertFalse(s.debugBasketIdentifiers.contains("B"))
    }

    func testSwipeBackShowsRestoredItem() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C", "D"], historyIndex: 1)
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        _ = s.advance() // C
        _ = s.advance() // D
        _ = s.restoreBasketed("B", previousNeighborID: "A", nextNeighborID: "C", seekIfNear: false)
        XCTAssertEqual(s.currentIdentifier, "D") // far away — do not yank
        XCTAssertEqual(s.goBack(), "C")
        XCTAssertEqual(s.goBack(), "B") // restored reappears in reverse history
        XCTAssertEqual(s.goBack(), "A")
    }

    func testRestoreManyPreservesOrderAndLandsOnAdjacent() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C", "D"], historyIndex: 0)
        s.noteBasketed("A", previousNeighborID: nil, nextNeighborID: "B")
        _ = s.advance() // B
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        _ = s.advance() // C
        s.noteBasketed("C", previousNeighborID: "B", nextNeighborID: "D")
        _ = s.advance() // D
        XCTAssertEqual(s.currentIdentifier, "D")

        let landed = s.restoreBasketedMany(
            [
                (id: "A", previousNeighborID: nil, nextNeighborID: "B"),
                (id: "B", previousNeighborID: "A", nextNeighborID: "C"),
                (id: "C", previousNeighborID: "B", nextNeighborID: "D"),
            ],
            seekIfNear: true
        )
        XCTAssertTrue(landed)
        XCTAssertEqual(s.currentIdentifier, "C") // adjacent before D — do not skip past block
        XCTAssertEqual(s.debugHistory, ["A", "B", "C", "D"])
        XCTAssertEqual(s.goBack(), "B")
        XCTAssertEqual(s.goBack(), "A")
    }

    func testRestoreInsertsUsingNeighborsWhenMissingFromHistory() {
        let s = FeedSampler()
        // Simulate pre-fix scrubbed history: only neighbors remain.
        s.debugInstallSession(history: ["A", "C"], historyIndex: 1) // on C
        let landed = s.restoreBasketed(
            "B",
            previousNeighborID: "A",
            nextNeighborID: "C",
            seekIfNear: true
        )
        XCTAssertTrue(landed)
        XCTAssertEqual(s.debugHistory, ["A", "B", "C"])
        XCTAssertEqual(s.currentIdentifier, "B")
    }

    func testPermanentDeleteScrubsGhosts() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C"], historyIndex: 2)
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        s.notePermanentlyDeleted(["B"])
        XCTAssertEqual(s.debugHistory, ["A", "C"])
        XCTAssertEqual(s.currentIdentifier, "C")
        XCTAssertFalse(s.debugBasketIdentifiers.contains("B"))
    }

    // MARK: - PhotoKit delete-all cancel (must NOT restore)

    /// PH confirmation Cancel / Don't Allow — pending ids stay basketed; feed stays excluded.
    func testPhotoKitCancelLeavesBasketIntact() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C"], historyIndex: 0)
        s.noteBasketed("A", previousNeighborID: nil, nextNeighborID: "B")
        _ = s.advance()
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        _ = s.advance()
        XCTAssertEqual(s.currentIdentifier, "C")

        let pendingBefore = s.debugBasketIdentifiers
        XCTAssertEqual(pendingBefore, Set(["A", "B"]))

        // Simulate delete-all → system Cancel (no restore, no permanent scrub).
        let outcome = DeleteCoordinator.outcome(forDeleteAllResult: false)
        XCTAssertEqual(outcome, .cancelledOrFailed)
        XCTAssertFalse(DeleteCoordinator.shouldRestoreToFeed(after: outcome))
        XCTAssertFalse(DeleteCoordinator.shouldClearBasket(after: outcome))

        // Sampler untouched — still excluded from feed sequence.
        XCTAssertEqual(s.debugBasketIdentifiers, pendingBefore)
        XCTAssertEqual(s.debugBasketIdentifiers.count, 2)
        XCTAssertNil(s.peekPrevIdentifier()) // A/B still basketed ghosts behind C
        // Swipe back must not resurface pending-delete items.
        XCTAssertFalse(s.canGoBack)
    }

    /// Undo after delete-all cancel is not a feed restore: items remain pending-delete.
    /// (Unlike single-item feed Undo or 全部移出, which do restore.)
    func testUndoAfterDeleteAllCancelDoesNotRestoreToFeed() {
        let s = FeedSampler()
        s.debugInstallSession(history: ["A", "B", "C"], historyIndex: 0)
        s.noteBasketed("A", previousNeighborID: nil, nextNeighborID: "B")
        _ = s.advance()
        s.noteBasketed("B", previousNeighborID: "A", nextNeighborID: "C")
        _ = s.advance()

        let outcome = DeleteCoordinator.outcome(forDeleteAllResult: false)
        XCTAssertFalse(DeleteCoordinator.shouldRestoreToFeed(after: outcome))

        // Basket exclusion must remain until explicit X / 全部移出.
        XCTAssertEqual(s.debugBasketIdentifiers, Set(["A", "B"]))
        XCTAssertEqual(s.currentIdentifier, "C")
        XCTAssertEqual(s.debugHistory, ["A", "B", "C"])
        XCTAssertEqual(s.peekNextIdentifier(), nil)
    }

    func testPhotoKitConfirmClearsBasketPolicy() {
        let outcome = DeleteCoordinator.outcome(forDeleteAllResult: true)
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertTrue(DeleteCoordinator.shouldClearBasket(after: outcome))
        // Confirmed delete clears basket via PhotoKit success path; restore-to-feed stays false
        // (assets are gone — permanent scrub, not feed restore).
        XCTAssertFalse(DeleteCoordinator.shouldRestoreToFeed(after: outcome))
    }
}
