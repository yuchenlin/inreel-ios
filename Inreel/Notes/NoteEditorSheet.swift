import SwiftUI
import Photos
import SwiftData

/// Shared notes UI for feed sheet and Notes tab detail.
struct NoteEditorSheet: View {
    let localIdentifier: String
    let asset: PHAsset?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var notes: [Note] = []
    @State private var draft = ""
    @State private var isSaving = false
    @FocusState private var inputFocused: Bool

    private var isUnlinked: Bool { asset == nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mediaHeader
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(Color.black)

                if isUnlinked {
                    unlinkedBanner
                }

                notesList

                inputBar
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(String(localized: "notes.editor.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "notes.editor.done")) {
                        dismiss()
                    }
                }
            }
            .task {
                NoteStore(context: modelContext).repairLocalIdentifiers()
                reload()
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var mediaHeader: some View {
        if let asset {
            LikedThumbnailView(asset: asset)
                .clipped()
        } else {
            ZStack {
                Color.white.opacity(0.06)
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.secondaryText)
                    Text(String(localized: "notes.unlinked"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var unlinkedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text(String(localized: "notes.unlinked.banner"))
                .font(.caption.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.85))
    }

    private var notesList: some View {
        Group {
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(String(localized: "notes.editor.empty"))
                        .font(.body)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(notes, id: \.persistentModelID) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.body)
                                .font(.body)
                                .foregroundStyle(Theme.primaryText)
                                .textSelection(.enabled)
                            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .listRowBackground(Color.white.opacity(0.06))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteNote(note)
                            } label: {
                                Label(String(localized: "notes.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(String(localized: "notes.input.placeholder"), text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
                .focused($inputFocused)

            Button {
                Task { await saveDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Theme.accent : Theme.secondaryText)
            }
            .disabled(!canSend || isSaving)
            .accessibilityLabel(Text(String(localized: "notes.send")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reload() {
        let store = NoteStore(context: modelContext)
        notes = (try? store.notes(for: localIdentifier)) ?? []
    }

    private func deleteNote(_ note: Note) {
        do {
            try NoteStore(context: modelContext).delete(note)
            reload()
            Haptics.light()
        } catch {
            assertionFailure("Note delete failed: \(error)")
        }
    }

    @MainActor
    private func saveDraft() async {
        guard canSend, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try NoteStore(context: modelContext).add(
                body: draft,
                localIdentifier: localIdentifier
            )
            draft = ""
            reload()
            Haptics.medium()
        } catch {
            Haptics.light()
        }
    }
}

/// Identifiable wrapper so feed / list can present the same sheet.
struct NotesPresentation: Identifiable {
    let id: String
    let asset: PHAsset?

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }

    init(localIdentifier: String, asset: PHAsset?) {
        self.id = localIdentifier
        self.asset = asset
    }
}
