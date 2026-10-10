import SwiftUI
import Photos

struct OnboardingView: View {
    @Binding var authStatus: PHAuthorizationStatus
    /// Owned by RootView so it survives authStatus updates that used to recreate this view.
    @Binding var page: Int
    @Binding var hasCompletedOnboarding: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasLibraryAccess: Bool {
        authStatus == .authorized || authStatus == .limited
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    onboardingPage(
                        title: String(localized: "onboarding.page1.title"),
                        bodyText: String(localized: "onboarding.page1.body"),
                        tag: 0
                    )
                    onboardingPage(
                        title: String(localized: "onboarding.page2.title"),
                        bodyText: String(localized: "onboarding.page2.body"),
                        tag: 1
                    )
                    // Always present so granting access does not insert a page and reset selection.
                    onboardingPage(
                        title: String(localized: "onboarding.page3.title"),
                        bodyText: String(localized: "onboarding.page3.body"),
                        tag: 2
                    )
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(reduceMotion ? Motion.reduced : Motion.onboardingPage, value: page)
                .onChange(of: page) { _, newPage in
                    // Page 3 is post-authorization only (§5.1).
                    if newPage == 2, !hasLibraryAccess {
                        page = 1
                    }
                }

                bottomButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    private func onboardingPage(title: String, bodyText: String, tag: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .default))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .tag(tag)
    }

    @ViewBuilder
    private var bottomButton: some View {
        if page < 1 {
            Button {
                withAnimation(reduceMotion ? Motion.reduced : Motion.onboardingPage) { page = 1 }
            } label: {
                Text(String(localized: "onboarding.continue"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if page == 1, !hasLibraryAccess {
            Button {
                Task { await requestAccess() }
            } label: {
                Text(String(localized: "onboarding.allowPhotos"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else {
            // Page 3 after grant (or Start if already on page 2).
            Button {
                hasCompletedOnboarding = true
            } label: {
                Text(String(localized: "onboarding.start"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    @MainActor
    private func requestAccess() async {
        let status = await PhotoLibrary.requestAuthorization()
        authStatus = status
        switch status {
        case .authorized, .limited:
            withAnimation(reduceMotion ? Motion.reduced : Motion.onboardingPage) { page = 2 }
        case .denied, .restricted:
            break
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
    }
}
