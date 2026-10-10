import Foundation
import SwiftData

@Model
final class SeenRecord {
    @Attribute(.unique) var localIdentifier: String
    var cloudIdentifier: String?
    var seenAt: Date
    var cooldownUntil: Date

    init(
        localIdentifier: String,
        cloudIdentifier: String? = nil,
        seenAt: Date = .now,
        cooldownUntil: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.seenAt = seenAt
        self.cooldownUntil = cooldownUntil
    }
}

/// Stub for schema honesty (notes UI is a later step).
@Model
final class Note {
    var localIdentifier: String
    var cloudIdentifier: String?
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(
        localIdentifier: String,
        cloudIdentifier: String? = nil,
        body: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Stub for schema honesty (basket UI / delete is a later step).
/// Pending-delete queue row. Neighbor ids anchor feed-sequence restore on undo / remove / PhotoKit cancel.
@Model
final class BasketItem {
    @Attribute(.unique) var localIdentifier: String
    var cloudIdentifier: String?
    var addedAt: Date
    var estimatedByteCount: Int64
    /// Feed history neighbor behind this item when it was basketed (`nil` if unknown / Liked origin).
    var previousNeighborID: String?
    /// Feed history neighbor ahead of this item when it was basketed (`nil` if unknown / Liked origin).
    var nextNeighborID: String?

    init(
        localIdentifier: String,
        cloudIdentifier: String? = nil,
        addedAt: Date = .now,
        estimatedByteCount: Int64 = 0,
        previousNeighborID: String? = nil,
        nextNeighborID: String? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.addedAt = addedAt
        self.estimatedByteCount = estimatedByteCount
        self.previousNeighborID = previousNeighborID
        self.nextNeighborID = nextNeighborID
    }
}

/// Stub for schema honesty (stats UI is a later step).
@Model
final class Stats {
    var totalSeen: Int
    var totalLiked: Int
    var totalDeleted: Int
    var totalNotes: Int
    var lastDeletedAt: Date?

    init(
        totalSeen: Int = 0,
        totalLiked: Int = 0,
        totalDeleted: Int = 0,
        totalNotes: Int = 0,
        lastDeletedAt: Date? = nil
    ) {
        self.totalSeen = totalSeen
        self.totalLiked = totalLiked
        self.totalDeleted = totalDeleted
        self.totalNotes = totalNotes
        self.lastDeletedAt = lastDeletedAt
    }
}

enum CooldownOption: Int, CaseIterable, Identifiable {
    case days30 = 30
    case days90 = 90
    case days180 = 180
    case days365 = 365
    case untilExhausted = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .days30: String(localized: "settings.cooldown.30")
        case .days90: String(localized: "settings.cooldown.90")
        case .days180: String(localized: "settings.cooldown.180")
        case .days365: String(localized: "settings.cooldown.365")
        case .untilExhausted: String(localized: "settings.cooldown.exhausted")
        }
    }

    static func from(days: Int) -> CooldownOption {
        CooldownOption(rawValue: days) ?? .days180
    }
}

enum AppSettings {
    static let feedFilterKey = "feedFilter"
    static let legacyFeedTrackKey = "feedTrack"
    static let cooldownDaysKey = "cooldownDays"
    static let autoplayKey = "autoplay"
    static let showDateKey = "showDate"
    /// When true, feed chrome shows calendar dates instead of relative ("3 years ago"). Default ON.
    static let showExactDatesKey = "showExactDates"
    static let showSizeKey = "showSize"
    static let showTimeKey = "showTime"
    static let showLocationKey = "showLocation"
    static let showDeviceKey = "showDevice"
    static let showAlbumsKey = "showAlbums"
    /// Global video sound (true = sound on), owned by `MuteState`. Written by both the Settings
    /// toggle and the feed speaker button / volume keys — last change wins. Default OFF (muted).
    static let alwaysUnmutedKey = "alwaysUnmuted"
    /// When true, bottom tab bar stays visible on Feed. Default ON = Always visible (常驻).
    static let tabBarAlwaysVisibleKey = "tabBarAlwaysVisible"
    /// One-shot: flip product default to Always visible for builds that previously migrated to Auto-hide.
    static let tabBarAlwaysVisibleDefaultOnB39Key = "tabBarAlwaysVisible_defaultOn_b39"

    /// Spec default: 180 days. 0 = until track exhausted (cooldownUntil = distantFuture).
    static let defaultCooldownDays = 180

    static func migrateFeedFilterIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: feedFilterKey) == nil {
            if let legacy = defaults.string(forKey: legacyFeedTrackKey) {
                defaults.set(legacy, forKey: feedFilterKey)
            } else {
                defaults.set(FeedTrack.default.rawValue, forKey: feedFilterKey)
            }
        }
        if defaults.object(forKey: cooldownDaysKey) == nil {
            defaults.set(defaultCooldownDays, forKey: cooldownDaysKey)
        }
        if defaults.object(forKey: autoplayKey) == nil {
            defaults.set(true, forKey: autoplayKey)
        }
        if defaults.object(forKey: showDateKey) == nil {
            defaults.set(true, forKey: showDateKey)
        }
        if defaults.object(forKey: showExactDatesKey) == nil {
            defaults.set(true, forKey: showExactDatesKey)
        }
        if defaults.object(forKey: showSizeKey) == nil {
            defaults.set(false, forKey: showSizeKey)
        }
        if defaults.object(forKey: showTimeKey) == nil {
            defaults.set(true, forKey: showTimeKey)
        }
        if defaults.object(forKey: showLocationKey) == nil {
            defaults.set(true, forKey: showLocationKey)
        }
        if defaults.object(forKey: showDeviceKey) == nil {
            defaults.set(true, forKey: showDeviceKey)
        }
        if defaults.object(forKey: showAlbumsKey) == nil {
            defaults.set(true, forKey: showAlbumsKey)
        }
        if defaults.object(forKey: alwaysUnmutedKey) == nil {
            defaults.set(false, forKey: alwaysUnmutedKey)
        }
        if defaults.object(forKey: tabBarAlwaysVisibleKey) == nil {
            defaults.set(true, forKey: tabBarAlwaysVisibleKey)
        }
        // Pre-launch b39: product default flipped Auto-hide → Always visible once.
        if defaults.object(forKey: tabBarAlwaysVisibleDefaultOnB39Key) == nil {
            defaults.set(true, forKey: tabBarAlwaysVisibleKey)
            defaults.set(true, forKey: tabBarAlwaysVisibleDefaultOnB39Key)
        }
    }
}
