import SwiftUI
import Photos
import SwiftData

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Note.createdAt, order: .reverse) private var allNotes: [Note]

    @State private var summaries: [NoteAssetSummary] = []
    @State private var presentation: NotesPresentation?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if summaries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(summaries) { summary in
                            Button {
                                let asset = NoteStore(context: modelContext)
                                    .fetchAsset(localIdentifier: summary.localIdentifier)
                                presentation = NotesPresentation(
                                    localIdentifier: summary.localIdentifier,
                                    asset: asset
                                )
                            } label: {
                                NotesRowView(summary: summary)
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                            .listRowSeparatorTint(.white.opacity(0.12))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .safeAreaPadding(.bottom, Theme.floatingTabClearance)
            .navigationTitle(String(localized: "tab.notes"))
            .navigationBarTitleDisplayMode(.inline)
            .task { refresh() }
            .onChange(of: allNotes.count) { _, _ in
                refresh()
            }
            .sheet(item: $presentation) { item in
                NoteEditorSheet(localIdentifier: item.id, asset: item.asset)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(String(localized: "notes.empty.title"))
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
            Text(String(localized: "notes.empty.body"))
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func refresh() {
        let store = NoteStore(context: modelContext)
        store.repairLocalIdentifiers()
        summaries = (try? store.assetSummaries()) ?? []
    }
}

private struct NotesRowView: View {
    let summary: NoteAssetSummary
    @State private var asset: PHAsset?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 56, height: 56)
                if let asset {
                    LikedThumbnailView(asset: asset)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.latestAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    if summary.isUnlinked {
                        Text(String(localized: "notes.unlinked"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if summary.noteCount > 1 {
                        Text("\(summary.noteCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Text(summary.latestBody)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 4)
        .task {
            asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [summary.localIdentifier],
                options: nil
            ).firstObject
        }
    }
}
