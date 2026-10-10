import Foundation
import SwiftData

enum NoteExport {
    static func plainText(notes: [Note]) -> String {
        let grouped = Dictionary(grouping: notes, by: \.localIdentifier)
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        for (localID, group) in grouped.sorted(by: { $0.key < $1.key }) {
            lines.append("# \(localID)")
            for note in group.sorted(by: { $0.createdAt < $1.createdAt }) {
                lines.append("- [\(formatter.string(from: note.createdAt))] \(note.body)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func jsonData(notes: [Note]) throws -> Data {
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = notes
            .sorted { $0.createdAt < $1.createdAt }
            .map { note in
                var row: [String: Any] = [
                    "localIdentifier": note.localIdentifier,
                    "body": note.body,
                    "createdAt": iso.string(from: note.createdAt),
                    "updatedAt": iso.string(from: note.updatedAt),
                ]
                if let cloud = note.cloudIdentifier {
                    row["cloudIdentifier"] = cloud
                }
                return row
            }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
