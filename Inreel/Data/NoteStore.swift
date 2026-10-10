import Foundation
import SwiftData
import Photos

struct NoteAssetSummary: Identifiable, Hashable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let cloudIdentifier: String?
    let latestBody: String
    let latestAt: Date
    let noteCount: Int
    /// True when PhotoKit no longer resolves this localIdentifier.
    let isUnlinked: Bool
}

@MainActor
final class NoteStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func notes(for localIdentifier: String) throws -> [Note] {
        let id = localIdentifier
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.localIdentifier == id },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func noteCount(for localIdentifier: String) throws -> Int {
        try notes(for: localIdentifier).count
    }

    @discardableResult
    func add(body: String, localIdentifier: String) throws -> Note {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteStoreError.emptyBody
        }
        let now = Date()
        let note = Note(
            localIdentifier: localIdentifier,
            cloudIdentifier: CloudIDMapper.cloudIdentifier(for: localIdentifier),
            body: trimmed,
            createdAt: now,
            updatedAt: now
        )
        context.insert(note)
        try context.save()
        StatsStore.incrementNotes(in: context)
        return note
    }

    func delete(_ note: Note) throws {
        context.delete(note)
        try context.save()
    }

    /// One row per asset that has at least one note, newest activity first.
    func assetSummaries() throws -> [NoteAssetSummary] {
        let all = try context.fetch(
            FetchDescriptor<Note>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        var order: [String] = []
        var latest: [String: Note] = [:]
        var counts: [String: Int] = [:]
        var clouds: [String: String?] = [:]

        for note in all {
            let id = note.localIdentifier
            counts[id, default: 0] += 1
            if latest[id] == nil {
                latest[id] = note
                order.append(id)
                clouds[id] = note.cloudIdentifier
            }
        }

        return order.compactMap { id in
            guard let note = latest[id] else { return nil }
            let asset = fetchAsset(localIdentifier: id)
            return NoteAssetSummary(
                localIdentifier: id,
                cloudIdentifier: clouds[id] ?? note.cloudIdentifier,
                latestBody: note.body,
                latestAt: note.createdAt,
                noteCount: counts[id] ?? 1,
                isUnlinked: asset == nil
            )
        }
    }

    func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Best-effort repair of Note.localIdentifier via stored cloudIdentifier. Never deletes notes.
    func repairLocalIdentifiers() {
        let descriptor = FetchDescriptor<Note>()
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }

        let pairs: [(Note, PHCloudIdentifier)] = records.compactMap { note in
            guard let cloud = note.cloudIdentifier else { return nil }
            return (note, CloudIDMapper.makeCloudIdentifier(from: cloud))
        }
        guard !pairs.isEmpty else { return }

        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: pairs.map(\.1))
        var changed = false
        for (note, cloudID) in pairs {
            guard let result = mappings[cloudID] else { continue }
            if case .success(let localID) = result, localID != note.localIdentifier {
                note.localIdentifier = localID
                changed = true
            }
            // Mapping failure: leave note keyed by localIdentifier (失联 in UI if asset missing).
        }
        if changed {
            try? context.save()
        }
    }
}

enum NoteStoreError: Error {
    case emptyBody
}
