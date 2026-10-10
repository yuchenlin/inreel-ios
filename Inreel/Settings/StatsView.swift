import SwiftUI
import SwiftData

/// Done-list stats (not a todo of remaining work).
struct StatsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot = StatsSnapshot(
        totalSeen: 0,
        totalLiked: 0,
        totalDeleted: 0,
        totalNotes: 0,
        pendingBasket: 0,
        lastDeletedAt: nil
    )

    var body: some View {
        List {
            Section {
                statRow(String(localized: "stats.seen"), value: snapshot.totalSeen)
                statRow(String(localized: "stats.liked"), value: snapshot.totalLiked)
                statRow(String(localized: "stats.deleted"), value: snapshot.totalDeleted)
                statRow(String(localized: "stats.notes"), value: snapshot.totalNotes)
            } footer: {
                Text(String(localized: "stats.footer"))
                    .foregroundStyle(Theme.secondaryText)
            }

            if snapshot.pendingBasket > 0 {
                Section {
                    statRow(String(localized: "stats.basket"), value: snapshot.pendingBasket)
                }
            }

            if let last = snapshot.lastDeletedAt {
                Section {
                    LabeledContent(String(localized: "stats.lastDeleted")) {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "stats.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onAppear { reload() }
        .preferredColorScheme(.dark)
    }

    private func statRow(_ title: String, value: Int) -> some View {
        LabeledContent(title) {
            Text("\(value)")
                .foregroundStyle(Theme.primaryText)
                .fontWeight(.semibold)
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func reload() {
        snapshot = StatsStore.snapshot(in: modelContext)
    }
}
