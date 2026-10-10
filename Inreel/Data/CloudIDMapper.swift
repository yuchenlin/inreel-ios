import Foundation
import Photos

/// Maps local identifiers to PHCloudIdentifier archival/string values for stable SeenRecord keys.
enum CloudIDMapper {
    static func cloudIdentifier(for localIdentifier: String) -> String? {
        cloudIdentifiers(for: [localIdentifier])[localIdentifier]
    }

    static func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        guard !localIdentifiers.isEmpty else { return [:] }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        var result: [String: String] = [:]
        result.reserveCapacity(mappings.count)
        for (localID, mappingResult) in mappings {
            if case .success(let cloudID) = mappingResult {
                result[localID] = Self.stableString(for: cloudID)
            }
        }
        return result
    }

    static func makeCloudIdentifier(from stored: String) -> PHCloudIdentifier {
        if #available(iOS 18.2, *) {
            return PHCloudIdentifier(archivalStringValue: stored) ?? PHCloudIdentifier(stringValue: stored)
        }
        return PHCloudIdentifier(stringValue: stored)
    }

    static func stableString(for cloudID: PHCloudIdentifier) -> String {
        if #available(iOS 18.2, *) {
            return cloudID.archivalStringValue
        }
        return cloudID.stringValue
    }
}
