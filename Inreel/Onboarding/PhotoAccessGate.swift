import SwiftUI
import Photos

/// Shown when photo library access is denied or restricted.
/// Never enters an empty feed pretending to have the full library.
struct PhotoAccessGate: View {
    let authStatus: PHAuthorizationStatus
    var onRecheck: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                Text(String(localized: "gate.title"))
                    .font(.title2.bold())
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                Text(String(localized: "gate.body"))
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(String(localized: "gate.openSettings"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
            }
            .padding(32)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            onRecheck()
        }
    }
}
