import SwiftUI
import Photos

struct LikedGridView: View {
    @State private var filter: LikedFilter = .all
    @State private var assets: [PHAsset] = []
    @State private var isLoading = true
    @State private var viewerSession: LikedViewerSession?
    @State private var libraryObserver: LikedLibraryObserver?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    private var filtered: [PHAsset] {
        assets.filter { filter.matches($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if filtered.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.localIdentifier) { index, asset in
                                Button {
                                    viewerSession = LikedViewerSession(
                                        assets: filtered,
                                        index: index
                                    )
                                } label: {
                                    LikedThumbnailView(asset: asset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 8)
                    }
                }
            }
            .safeAreaPadding(.bottom, Theme.floatingTabClearance)
            .navigationTitle(String(localized: "tab.liked"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(String(localized: "liked.filter.label"), selection: $filter) {
                        ForEach(LikedFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
            .task { await reload() }
            .onAppear {
                startObserving()
                // Keep view alive across tab switches — always refresh when returning.
                Task { await reload() }
            }
            .onChange(of: isLoading) { _, loading in
                // QA hook: `defaults write … debugOpenFirstLiked 1` then launch once.
                guard !loading, viewerSession == nil else { return }
                let key = "debugOpenFirstLiked"
                guard UserDefaults.standard.bool(forKey: key) else { return }
                UserDefaults.standard.removeObject(forKey: key)
                let items = filtered
                guard !items.isEmpty else { return }
                viewerSession = LikedViewerSession(assets: items, index: 0)
            }
            .onDisappear { stopObserving() }
            .onReceive(NotificationCenter.default.publisher(for: .inreelFavoritesDidChange)) { _ in
                Task { await reload() }
            }
            .fullScreenCover(item: $viewerSession, onDismiss: {
                Task { await reload() }
            }) { session in
                LikedViewerSessionHost(session: session)
                    // Explicit so the presented viewer always shares the global mute state.
                    .environment(MuteState.shared)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(String(localized: "liked.empty.title"))
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
            Text(String(localized: "liked.empty.body"))
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    @MainActor
    private func reload() async {
        isLoading = assets.isEmpty
        let fetched = await Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchFavorites()
        }.value
        assets = fetched
        isLoading = false
    }

    private func startObserving() {
        guard libraryObserver == nil else { return }
        let observer = LikedLibraryObserver {
            Task { @MainActor in
                await reload()
            }
        }
        libraryObserver = observer
        PHPhotoLibrary.shared().register(observer)
    }

    private func stopObserving() {
        if let libraryObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(libraryObserver)
            self.libraryObserver = nil
        }
    }
}

/// Reloads the liked grid when system Favorites change.
private final class LikedLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

// MARK: - Viewer presentation

/// Identifiable session so `fullScreenCover(item:)` always receives the tapped assets
/// (avoids stale/empty capture with `isPresented` that painted a black Liked viewer).
private struct LikedViewerSession: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
    var index: Int
}

private struct LikedViewerSessionHost: View {
    let session: LikedViewerSession
    @State private var index: Int

    init(session: LikedViewerSession) {
        self.session = session
        _index = State(initialValue: session.index)
    }

    var body: some View {
        LikedViewerView(assets: session.assets, index: $index)
    }
}
