import Foundation
import SwiftData

struct StatsSnapshot {
    var totalSeen: Int
    var totalLiked: Int
    var totalDeleted: Int
    var totalNotes: Int
    var pendingBasket: Int
    var lastDeletedAt: Date?
}

/// Stats counters are written only by `StatsWriter` (background context), so callers never wait
/// on a SwiftData save and the main context never holds a stale `Stats` row.
@MainActor
enum StatsStore {
    static func incrementLiked(in context: ModelContext) {
        incrementLiked(container: context.container)
    }

    static func incrementLiked(container: ModelContainer) {
        enqueue(.liked, container: container)
    }

    static func incrementDeleted(by count: Int, in context: ModelContext) {
        guard count > 0 else { return }
        enqueue(.deleted(count, at: .now), container: context.container)
    }

    static func incrementNotes(in context: ModelContext) {
        enqueue(.notes, container: context.container)
    }

    /// Done-list counts: prefer live row counts where they exist; fall back to Stats counters.
    static func snapshot(in context: ModelContext) -> StatsSnapshot {
        let seenCount = (try? context.fetchCount(FetchDescriptor<SeenRecord>())) ?? 0
        let noteCount = (try? context.fetchCount(FetchDescriptor<Note>())) ?? 0
        let basketCount = (try? context.fetchCount(FetchDescriptor<BasketItem>())) ?? 0
        // Fresh context: reads the latest background-written counters from the store.
        let statsContext = ModelContext(context.container)
        let stats = (try? statsContext.fetch(FetchDescriptor<Stats>()))?.first
        return StatsSnapshot(
            totalSeen: max(seenCount, stats?.totalSeen ?? 0),
            totalLiked: stats?.totalLiked ?? 0,
            totalDeleted: stats?.totalDeleted ?? 0,
            totalNotes: max(noteCount, stats?.totalNotes ?? 0),
            pendingBasket: basketCount,
            lastDeletedAt: stats?.lastDeletedAt
        )
    }

    private static func enqueue(_ change: StatsWriter.Change, container: ModelContainer) {
        Task.detached(priority: .utility) {
            await StatsWriter.shared.apply(change, container: container)
        }
    }
}

/// Serializes Stats mutations off the main thread on a short-lived background ModelContext.
actor StatsWriter {
    static let shared = StatsWriter()

    enum Change: Sendable {
        case liked
        case deleted(Int, at: Date)
        case notes
    }

    func apply(_ change: Change, container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let stats: Stats
            if let existing = try context.fetch(FetchDescriptor<Stats>()).first {
                stats = existing
            } else {
                stats = Stats()
                context.insert(stats)
            }
            switch change {
            case .liked:
                stats.totalLiked += 1
            case .deleted(let count, let date):
                stats.totalDeleted += count
                stats.lastDeletedAt = date
            case .notes:
                stats.totalNotes += 1
            }
            try context.save()
        } catch {
            assertionFailure("Stats save failed: \(error)")
        }
    }
}
