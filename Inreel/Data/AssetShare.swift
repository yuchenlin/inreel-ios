import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import AVFoundation

/// Builds local activity items for the system share sheet from a `PHAsset`.
/// Does not upload to Inreel servers — only prepares media for `UIActivityViewController`.
enum AssetShare {
    enum ShareError: Error {
        case unavailable
        case exportFailed
        case cancelled
    }

    /// Prepare shareable items (temp file URLs preferred for Messages / other apps).
    /// Allows network only so PhotoKit can pull an iCloud original when needed.
    static func activityItems(for asset: PHAsset) async throws -> [Any] {
        if asset.mediaType == .video {
            return [try await exportVideoFile(for: asset)]
        }
        return [try await exportImageFile(for: asset)]
    }

    // MARK: - Image

    private static func exportImageFile(for asset: PHAsset) async throws -> URL {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.resizeMode = .none

        let packet: (Data?, String?, [AnyHashable: Any]?) = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, uti, _, info in
                continuation.resume(returning: (data, uti, info))
            }
        }

        if let info = packet.2 {
            if (info[PHImageCancelledKey] as? Bool) == true { throw ShareError.cancelled }
            if info[PHImageErrorKey] != nil { throw ShareError.exportFailed }
        }
        guard let data = packet.0, !data.isEmpty else { throw ShareError.unavailable }

        let ext = fileExtension(forUTI: packet.1, fallback: "jpg")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inreel-share-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Video

    private static func exportVideoFile(for asset: PHAsset) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        if let avURL = await requestAVURLAsset(for: asset, options: options),
           avURL.url.isFileURL,
           ((try? avURL.url.checkResourceIsReachable()) ?? false) {
            return try copyToTemp(avURL.url, preferredExtension: "mov")
        }

        let sessionOptional: AVAssetExportSession? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPresetHighestQuality
            ) { exportSession, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: exportSession)
            }
        }
        guard let session = sessionOptional else { throw ShareError.unavailable }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inreel-share-\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return outURL
        case .cancelled:
            throw ShareError.cancelled
        default:
            throw ShareError.exportFailed
        }
    }

    private static func requestAVURLAsset(
        for asset: PHAsset,
        options: PHVideoRequestOptions
    ) async -> AVURLAsset? {
        await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                continuation.resume(returning: avAsset as? AVURLAsset)
            }
        }
    }

    private static func copyToTemp(_ source: URL, preferredExtension: String) throws -> URL {
        let ext = source.pathExtension.isEmpty ? preferredExtension : source.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("inreel-share-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func fileExtension(forUTI uti: String?, fallback: String) -> String {
        guard let uti, let type = UTType(uti), let ext = type.preferredFilenameExtension else {
            return fallback
        }
        return ext
    }
}
