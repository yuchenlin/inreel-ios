import SwiftUI
import Photos
import SwiftData

struct BasketView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \BasketItem.addedAt, order: .reverse) private var items: [BasketItem]

    @State private var isDeleting = false
    @State private var toastText: String?
    @State private var thumbnailAssets: [String: PHAsset] = [:]
    @State private var showEmptyAllConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    private var totalBytes: Int64? {
        BasketStore.totalKnownBytes(in: items)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(items, id: \.localIdentifier) { item in
                                basketCell(item)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        deleteBar
                    }
                }

                if let toastText {
                    VStack {
                        Spacer()
                        Text(toastText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.18))
                            )
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }
                    .safeAreaPadding(.bottom, Theme.floatingTabClearance)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(String(localized: "tab.basket"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Image(systemName: "chart.bar.fill")
                    }
                    .accessibilityLabel(Text(String(localized: "stats.title")))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Single Empty-all control (toolbar only — not duplicated in bottom bar).
                    if !items.isEmpty {
                        Button {
                            showEmptyAllConfirm = true
                        } label: {
                            Text(String(localized: "basket.emptyAll"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .disabled(isDeleting)
                        .accessibilityLabel(Text(String(localized: "basket.emptyAll")))
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel(Text(String(localized: "settings.title")))
                }
            }
            .confirmationDialog(
                String(localized: "basket.emptyAll.confirm.title"),
                isPresented: $showEmptyAllConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "basket.emptyAll.confirm.action"), role: .destructive) {
                    emptyAllFromBasket()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "basket.emptyAll.confirm.message"))
            }
            .task { refreshThumbnails() }
            .onChange(of: items.map(\.localIdentifier)) { _, _ in
                refreshThumbnails()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 10) {
                Text(String(localized: "basket.empty.title"))
                    .font(.title3.bold())
                    .foregroundStyle(Theme.primaryText)
                Text(String(localized: "basket.empty.body"))
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            Spacer()
            // Thumb-zone hint above the floating tab pill.
            VStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                Text(String(localized: "basket.empty.hint"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, Theme.floatingTabClearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Single primary delete CTA; Empty-all lives in the toolbar only.
    private var deleteBar: some View {
        VStack(spacing: 6) {
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                Task { await confirmDelete() }
            } label: {
                Text(ctaTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isDeleting || items.isEmpty)
            .opacity(isDeleting ? 0.7 : 1)

            Text(String(localized: "basket.bar.hint"))
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        // Shared clearance = bar height + gap above home-indicator baseline.
        .padding(.bottom, Theme.floatingTabClearance)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var summaryLine: String {
        let n = items.count
        if let bytes = totalBytes, bytes > 0 {
            let size = BasketStore.formatByteCount(bytes)
            return String(format: String(localized: "basket.summary"), locale: .current, n, size)
        }
        return String(format: String(localized: "basket.summary.count"), locale: .current, n)
    }

    private var ctaTitle: String {
        let n = items.count
        if let bytes = totalBytes, bytes > 0 {
            let size = BasketStore.formatByteCount(bytes)
            return String(format: String(localized: "basket.cta.size"), locale: .current, n, size)
        }
        return String(format: String(localized: "basket.cta"), locale: .current, n)
    }

    @ViewBuilder
    private func basketCell(_ item: BasketItem) -> some View {
        let id = item.localIdentifier
        ZStack(alignment: .topTrailing) {
            Group {
                if let asset = thumbnailAssets[id] {
                    LikedThumbnailView(asset: asset)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            // Thumbnails are display-only; must not steal the X hit target
            // (scaledToFill Image hit boxes were swallowing taps).
            .allowsHitTesting(false)

            Button {
                removeFromBasket(localIdentifier: id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(10)
            .accessibilityLabel(Text(String(localized: "basket.remove")))
            .accessibilityIdentifier("basket.remove.\(id)")
        }
    }

    /// Removes one pending item from the basket. SwiftData only — never PhotoKit.
    private func removeFromBasket(localIdentifier id: String) {
        // Remaining cells reflow with a critically-damped spring (no layout pop).
        // Reduce Motion: short fade only.
        withAnimation(reduceMotion ? Motion.reduced : Motion.listReflow) {
            removeFromBasketStore(localIdentifier: id)
        }
    }

    private func removeFromBasketStore(localIdentifier id: String) {
        let store = BasketStore(context: modelContext)
        do {
            let payloads = try store.removeReturningRestorePayloads(localIdentifiers: [id])
            BasketStore.postRestore(payloads)
            Haptics.light()
        } catch {
            // Fallback: snapshot anchors from @Query rows, then delete.
            var payloads: [BasketStore.RestorePayload] = []
            for item in items where item.localIdentifier == id {
                payloads.append(
                    BasketStore.RestorePayload(
                        id: item.localIdentifier,
                        previousNeighborID: item.previousNeighborID,
                        nextNeighborID: item.nextNeighborID
                    )
                )
                modelContext.delete(item)
            }
            try? modelContext.save()
            BasketStore.postRestore(payloads)
            Haptics.light()
        }
    }

    /// Clears the entire pending-delete basket without deleting any library assets.
    /// Each item is restored to its prior feed-sequence slot.
    private func emptyAllFromBasket() {
        guard !items.isEmpty, !isDeleting else { return }
        let store = BasketStore(context: modelContext)
        do {
            let payloads = try store.removeAllReturningRestorePayloads()
            BasketStore.postRestore(payloads)
            Haptics.light()
            withAnimation(reduceMotion ? Motion.reduced : Motion.toast) {
                toastText = String(localized: "basket.emptyAll.toast")
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Motion.toastDwell)
                withAnimation(reduceMotion ? Motion.reduced : Motion.toast) {
                    if toastText == String(localized: "basket.emptyAll.toast") {
                        toastText = nil
                    }
                }
            }
        } catch {
            Haptics.warning()
        }
    }

    private func refreshThumbnails() {
        let ids = items.map(\.localIdentifier)
        guard !ids.isEmpty else {
            thumbnailAssets = [:]
            return
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }
        thumbnailAssets = map
    }

    @MainActor
    private func confirmDelete() async {
        guard !items.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        let ids = items.map(\.localIdentifier)
        let count = ids.count
        do {
            // System confirmation dialog. Cancel / Don't Allow throws.
            try await DeleteCoordinator.deleteAssets(localIdentifiers: ids)
            let store = BasketStore(context: modelContext)
            try store.remove(localIdentifiers: ids)
            BasketStore.postPermanentDelete(localIdentifiers: ids)
            StatsStore.incrementDeleted(by: count, in: modelContext)
            Haptics.deleteSuccess()
            withAnimation(reduceMotion ? Motion.reduced : Motion.toast) {
                toastText = String(localized: "basket.deletedToast")
            }
            try? await Task.sleep(nanoseconds: Motion.toastDwell)
            withAnimation(reduceMotion ? Motion.reduced : Motion.toast) {
                toastText = nil
            }
        } catch {
            // User cancelled system dialog or PhotoKit failed — leave pending basket intact.
            // Do NOT clear basket and do NOT restore into the feed (unlike 全部移出 / single X / single undo).
            Haptics.warning()
        }
    }
}
