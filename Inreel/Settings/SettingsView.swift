import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage(AppSettings.feedFilterKey) private var feedFilterRaw = FeedTrack.default.rawValue
    @AppStorage(AppSettings.cooldownDaysKey) private var cooldownDays = AppSettings.defaultCooldownDays
    @AppStorage(AppSettings.autoplayKey) private var autoplay = true
    @AppStorage(AppSettings.showDateKey) private var showDate = true
    @AppStorage(AppSettings.showExactDatesKey) private var showExactDates = true
    @AppStorage(AppSettings.showSizeKey) private var showSize = false
    @AppStorage(AppSettings.showTimeKey) private var showTime = true
    @AppStorage(AppSettings.showLocationKey) private var showLocation = true
    @AppStorage(AppSettings.showDeviceKey) private var showDevice = true
    @AppStorage(AppSettings.showAlbumsKey) private var showAlbums = true
    /// Same persisted value as the feed speaker button — last change (here or in the feed) wins.
    @Environment(MuteState.self) private var muteState
    @AppStorage(AppSettings.tabBarAlwaysVisibleKey) private var tabBarAlwaysVisible = true

    @State private var confirmResetSeen = false
    @State private var didResetSeen = false
    @State private var sharePayload: SharePayload?
    @State private var exportError: String?

    var body: some View {
        List {
            trackSection
            cooldownSection
            playbackSection
            displaySection
            dataSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .safeAreaPadding(.bottom, Theme.floatingTabClearance)
        .navigationTitle(String(localized: "settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            String(localized: "settings.resetSeen.confirmTitle"),
            isPresented: $confirmResetSeen,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.resetSeen.confirm"), role: .destructive) {
                resetSeen()
            }
            Button(String(localized: "settings.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.resetSeen.confirmMessage"))
        }
        .alert(String(localized: "settings.resetSeen.doneTitle"), isPresented: $didResetSeen) {
            Button(String(localized: "settings.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.resetSeen.doneMessage"))
        }
        .alert(
            String(localized: "settings.export.failed"),
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button(String(localized: "settings.ok"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
        }
    }

    private var trackSection: some View {
        Section(String(localized: "settings.section.track")) {
            Picker(String(localized: "settings.track"), selection: $feedFilterRaw) {
                ForEach(FeedTrack.allCases) { track in
                    Text(track.title).tag(track.rawValue)
                }
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var cooldownSection: some View {
        Section {
            Picker(String(localized: "settings.cooldown"), selection: $cooldownDays) {
                ForEach(CooldownOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .listRowBackground(Color.white.opacity(0.06))
        } header: {
            Text(String(localized: "settings.section.cooldown"))
        } footer: {
            Text(String(localized: "settings.cooldown.footer"))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var playbackSection: some View {
        @Bindable var muteState = muteState
        return Section {
            Toggle(String(localized: "settings.autoplay"), isOn: $autoplay)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.alwaysUnmuted"), isOn: $muteState.soundOn)
                .listRowBackground(Color.white.opacity(0.06))
        } header: {
            Text(String(localized: "settings.section.playback"))
        } footer: {
            Text(String(localized: "settings.alwaysUnmuted.footer"))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var displaySection: some View {
        Section {
            Toggle(String(localized: "settings.showDate"), isOn: $showDate)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.showExactDates"), isOn: $showExactDates)
                .listRowBackground(Color.white.opacity(0.06))
                .disabled(!showDate)
            Toggle(String(localized: "settings.showTime"), isOn: $showTime)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.showLocation"), isOn: $showLocation)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.showDevice"), isOn: $showDevice)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.showAlbums"), isOn: $showAlbums)
                .listRowBackground(Color.white.opacity(0.06))
            Toggle(String(localized: "settings.showSize"), isOn: $showSize)
                .listRowBackground(Color.white.opacity(0.06))
            Picker(String(localized: "settings.tabBarMode"), selection: $tabBarAlwaysVisible) {
                Text(String(localized: "settings.tabBarMode.always")).tag(true)
                Text(String(localized: "settings.tabBarMode.autoHide")).tag(false)
            }
            .listRowBackground(Color.white.opacity(0.06))
        } header: {
            Text(String(localized: "settings.section.display"))
        } footer: {
            Text(String(localized: "settings.display.footer"))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var dataSection: some View {
        Section(String(localized: "settings.section.data")) {
            NavigationLink {
                StatsView()
            } label: {
                Label(String(localized: "stats.title"), systemImage: "chart.bar.fill")
            }
            .listRowBackground(Color.white.opacity(0.06))

            Button(String(localized: "settings.export.notes.json")) {
                exportNotes(asJSON: true)
            }
            .listRowBackground(Color.white.opacity(0.06))

            Button(String(localized: "settings.export.notes.text")) {
                exportNotes(asJSON: false)
            }
            .listRowBackground(Color.white.opacity(0.06))

            Button(role: .destructive) {
                confirmResetSeen = true
            } label: {
                Text(String(localized: "settings.resetSeen"))
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var aboutSection: some View {
        Section(String(localized: "settings.section.about")) {
            LabeledContent(String(localized: "settings.about.name")) {
                Text("Inreel")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Color.white.opacity(0.06))

            LabeledContent(String(localized: "settings.about.version")) {
                Text(appVersion)
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Color.white.opacity(0.06))

            Text(String(localized: "settings.about.privacy"))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func resetSeen() {
        do {
            try SeenStore(context: modelContext).resetAll()
            didResetSeen = true
            Haptics.medium()
        } catch {
            exportError = String(localized: "settings.resetSeen.failed")
        }
    }

    private func exportNotes(asJSON: Bool) {
        do {
            let notes = try modelContext.fetch(FetchDescriptor<Note>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            guard !notes.isEmpty else {
                exportError = String(localized: "settings.export.empty")
                return
            }
            if asJSON {
                let data = try NoteExport.jsonData(notes: notes)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inreel-notes.json")
                try data.write(to: url, options: .atomic)
                sharePayload = SharePayload(items: [url])
            } else {
                let text = NoteExport.plainText(notes: notes)
                sharePayload = SharePayload(items: [text])
            }
            Haptics.light()
        } catch {
            exportError = String(localized: "settings.export.failed")
        }
    }
}
