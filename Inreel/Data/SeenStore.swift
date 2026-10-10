import Foundation
import SwiftData
import Photos

/// Reads/writes SeenRecord cooldown rows. Does not hold photo bytes.
@MainActor
final class SeenStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Identifiers still inside their cooldown window.
    func activeCooldownIdentifiers(now: Date = .now) throws -> Set<String> {
        let descriptor = FetchDescriptor<SeenRecord>(
            predicate: #Predicate<SeenRecord> { record in
                record.cooldownUntil > now
            }
        )
        let records = try context.fetch(descriptor)
        return Set(records.map(\.localIdentifier))
    }

    /// Upsert seen + cooldown. `cooldownDays <= 0` means until-exhausted (distantFuture).
    func markSeen(
        localIdentifier: String,
        cooldownDays: Int,
        now: Date = .now
    ) {
        let cooldownUntil: Date
        if cooldownDays <= 0 {
            cooldownUntil = .distantFuture
        } else {
            cooldownUntil = now.addingTimeInterval(TimeInterval(cooldownDays) * 86_400)
        }

        let cloudID = CloudIDMapper.cloudIdentifier(for: localIdentifier)
        let targetID = localIdentifier

        let descriptor = FetchDescriptor<SeenRecord>(
            predicate: #Predicate<SeenRecord> { record in
                record.localIdentifier == targetID
            }
        )

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.seenAt = now
                existing.cooldownUntil = cooldownUntil
                if let cloudID {
                    existing.cloudIdentifier = cloudID
                }
            } else {
                context.insert(
                    SeenRecord(
                        localIdentifier: localIdentifier,
                        cloudIdentifier: cloudID,
                        seenAt: now,
                        cooldownUntil: cooldownUntil
                    )
                )
            }
            try context.save()
        } catch {
            // Non-fatal: feed continues without persisting this mark.
            assertionFailure("SeenRecord save failed: \(error)")
        }
    }

    /// Repair localIdentifier drift using stored cloudIdentifier mappings (best-effort on launch).
    func repairLocalIdentifiers() {
        let descriptor = FetchDescriptor<SeenRecord>()
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }

        let pairs: [(SeenRecord, PHCloudIdentifier)] = records.compactMap { record in
            guard let cloud = record.cloudIdentifier else { return nil }
            return (record, CloudIDMapper.makeCloudIdentifier(from: cloud))
        }
        guard !pairs.isEmpty else { return }

        let cloudIDs = pairs.map(\.1)
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIDs)

        var changed = false
        for (record, cloudID) in pairs {
            guard let mappingResult = mappings[cloudID] else { continue }
            if case .success(let localID) = mappingResult, localID != record.localIdentifier {
                record.localIdentifier = localID
                changed = true
            }
        }
        if changed {
            try? context.save()
        }
    }

    /// Deletes every SeenRecord (settings “reset seen”).
    func resetAll() throws {
        let records = try context.fetch(FetchDescriptor<SeenRecord>())
        for record in records {
            context.delete(record)
        }
        try context.save()
    }
}
