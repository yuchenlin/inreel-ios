import SwiftUI
import Photos
import SwiftData
import UIKit

struct RootView: View {
    @State private var authStatus: PHAuthorizationStatus
    /// Persists across launches so Start is not shown again after first completion.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Lifted out of OnboardingView so authStatus updates cannot reset the page.
    @State private var onboardingPage = 0

    private static let onboardingCompletedKey = "hasCompletedOnboarding"

    init() {
        let status = PhotoLibrary.currentAuthorizationStatus()
        _authStatus = State(initialValue: status)
        // Spec: cold start already authorized/limited → skip onboarding entirely.
        // Write UserDefaults before first frame so tips never flash for returning users.
        let key = Self.onboardingCompletedKey
        if !UserDefaults.standard.bool(forKey: key),
           status == .authorized || status == .limited {
            UserDefaults.standard.set(true, forKey: key)
        }
        Self.configureChromeAppearance()
    }

    /// Dark chrome from the first frame — avoids white nav flashes.
    /// Tabs are a plain ZStack+switch (no UITabBarController) so iOS 26 Liquid Glass
    /// cannot leave a ghost system tab under `FloatingTabBar`.
    private static func configureChromeAppearance() {
        let black = UIColor.black
        // Belt-and-suspenders: if any UITabBar still appears, keep it invisible.
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().isTranslucent = true

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = black
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    /// One onboarding host for notDetermined → post-grant tips (stable identity).
    private var showsOnboarding: Bool {
        if hasCompletedOnboarding { return false }
        switch authStatus {
        case .notDetermined, .authorized, .limited:
            return true
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if showsOnboarding {
                OnboardingView(
                    authStatus: $authStatus,
                    page: $onboardingPage,
                    hasCompletedOnboarding: $hasCompletedOnboarding
                )
            } else if authStatus == .denied || authStatus == .restricted {
                PhotoAccessGate(authStatus: authStatus) {
                    authStatus = PhotoLibrary.currentAuthorizationStatus()
                }
            } else {
                MainTabView(authStatus: authStatus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            authStatus = PhotoLibrary.currentAuthorizationStatus()
            if UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) {
                hasCompletedOnboarding = true
            }
            Haptics.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            authStatus = PhotoLibrary.currentAuthorizationStatus()
        }
    }
}

private struct TabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False when this tab page is mounted but not the selected tab (ZStack keep-alive).
    /// Feed uses this to pause/detach AVPlayers so Liked viewer can render the same assets.
    var isTabActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}

struct MainTabView: View {

    let authStatus: PHAuthorizationStatus
    @State private var selectedTab: AppTab = Self.initialTab()
    /// Auto-hide mode only: hide floating bar until user reveals (chevron / up-from-bottom).
    @State private var feedImmersive = false
    /// Settings: keep tab bar always on vs dynamic auto-hide. Default ON (Always visible).
    @AppStorage(AppSettings.tabBarAlwaysVisibleKey) private var tabBarAlwaysVisible = true
    /// Pending-delete count for Basket badge (same SwiftData source as Basket/Stats).
    @Query private var basketItems: [BasketItem]
    /// Fly-into-trash overlay + basket icon frame for Feed / Liked basket commits.
    @State private var basketFly = BasketFlyController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Effective immersive chrome: forced off when "always visible" is enabled.
    private var feedChromeImmersive: Bool {
        !tabBarAlwaysVisible && feedImmersive
    }

    private var feedImmersiveBinding: Binding<Bool> {
        Binding(
            get: { feedChromeImmersive },
            set: { newValue in
                if !tabBarAlwaysVisible {
                    feedImmersive = newValue
                }
            }
        )
    }


    /// Optional QA hook: `defaults write … debugStartTab basket` then launch once.
    private static func initialTab() -> AppTab {
        let key = "debugStartTab"
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .feed }
        UserDefaults.standard.removeObject(forKey: key)
        switch raw {
        case "liked": return .liked
        case "notes": return .notes
        case "basket": return .basket
        case "settings": return .settings
        default: return .feed
        }
    }

    private var showsFloatingTabBar: Bool {
        if tabBarAlwaysVisible { return true }
        return !(selectedTab == .feed && feedImmersive)
    }


    @ViewBuilder
    private func tabPage<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .environment(\.isTabActive, selectedTab == tab)
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .zIndex(selectedTab == tab ? 1 : 0)
            // Content swaps instantly (native tab feel); the pill owns the selection motion.
            // Without this the tab's spring transaction also eased page opacity ("double soften").
            .animation(nil, value: selectedTab)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep all tabs mounted (preserve Feed/Liked state) but never host a
            // UITabBarController — iOS 26 Liquid Glass otherwise ghosts under the pill.
            ZStack {
                tabPage(.feed) {
                    FeedView(
                        authStatus: authStatus,
                        immersive: feedImmersiveBinding,
                        onRevealTabs: {
                            withAnimation(reduceMotion ? Motion.reduced : Motion.chrome) {
                                feedImmersive = false
                            }
                            Haptics.soft()
                        }
                    )
                }
                tabPage(.liked) { LikedGridView() }
                tabPage(.notes) { NotesListView() }
                tabPage(.basket) { BasketView() }
                tabPage(.settings) {
                    NavigationStack { SettingsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tint(Theme.accent)
            .background(Theme.background.ignoresSafeArea())

            if showsFloatingTabBar {
                FloatingTabBar(
                    selection: $selectedTab,
                    basketCount: basketItems.count,
                    badgePulse: basketFly.landingTick
                )
                // Sit just above the home indicator (ZStack respects safe area).
                .padding(.bottom, 8)
                // Reduce Motion: fade the pill, no slide.
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(50)
            }

            // Fly-into-trash sits above tabs; never intercepts hits.
            BasketFlyOverlay(controller: basketFly)
                .zIndex(60)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: BasketChromeSpace.name)
        .onPreferenceChange(BasketTabAnchorKey.self) { rect in
            basketFly.updateBasketFrame(rect)
        }
        .environment(basketFly)
        // Chrome only (tab bar show/hide). Tab selection is animated by FloatingTabBar alone.
        .animation(reduceMotion ? Motion.reduced : Motion.chrome, value: feedChromeImmersive)
        .animation(reduceMotion ? Motion.reduced : Motion.chrome, value: tabBarAlwaysVisible)
        .animation(reduceMotion ? Motion.reduced : Motion.chrome, value: showsFloatingTabBar)
        .onAppear {
            if tabBarAlwaysVisible {
                feedImmersive = false
            } else if selectedTab == .feed {
                feedImmersive = true
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .feed && !tabBarAlwaysVisible {
                feedImmersive = true
            }
        }
        .onChange(of: tabBarAlwaysVisible) { _, always in
            if always {
                withAnimation(reduceMotion ? Motion.reduced : Motion.chrome) {
                    feedImmersive = false
                }
            } else if selectedTab == .feed {
                withAnimation(reduceMotion ? Motion.reduced : Motion.chrome) {
                    feedImmersive = true
                }
            }
        }
    }
}

enum AppTab: Hashable {
    case feed, liked, notes, basket, settings
}
