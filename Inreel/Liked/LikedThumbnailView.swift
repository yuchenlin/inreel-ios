import SwiftUI
import Photos
import UIKit

struct LikedThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    private static let manager = PHCachingImageManager()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.08)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                if asset.mediaType == .video {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "video.fill")
                                .font(.caption2.weight(.bold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { request() }
        .onDisappear { cancel() }
        .onChange(of: asset.localIdentifier) { _, _ in
            cancel()
            image = nil
            request()
        }
    }

    private func request() {
        let scale = UIScreen.main.scale
        let side = 120 * scale
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = Self.manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }
            if let result {
                Task { @MainActor in
                    self.image = result
                }
            }
        }
    }

    private func cancel() {
        if requestID != PHInvalidImageRequestID {
            Self.manager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
    }
}
