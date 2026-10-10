import SwiftUI

/// Instagram-style frosted floating tab pill. Icon-only; selected tab sits in a light capsule.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var basketCount: Int
    /// Bumps when a fly-to-trash thumb lands → the basket badge pops (spatial continuity).
    var badgePulse: Int = 0
    var onSelect: (AppTab) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var badgeScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.40), radius: 18, y: 6)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .onChange(of: badgePulse) { _, _ in
            // 1 → 1.08 → 1. Reduce Motion: no scale (the count change itself is the signal).
            guard !reduceMotion else { return }
            withAnimation(Motion.badgeBump) {
                badgeScale = Motion.badgeBumpScale
            } completion: {
                withAnimation(Motion.badgeBump) {
                    badgeScale = 1
                }
            }
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: AppTab) -> some View {
        let selected = selection == tab
        Button {
            if selection != tab {
                Haptics.selection()
            } else {
                Haptics.soft()
            }
            // Reduce Motion: color/opacity crossfade only (≤150ms).
            withAnimation(reduceMotion ? Motion.reduced : Motion.tabSelect) {
                selection = tab
            }
            onSelect(tab)
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(selected ? Color.white.opacity(0.94) : Color.clear)
                    .frame(width: 54, height: 36)
                    .shadow(color: selected ? .black.opacity(0.18) : .clear, radius: 4, y: 1)

                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.72))
                    .symbolRenderingMode(.hierarchical)
                    // Tight box around the glyph so the badge anchors to the icon, not the tab cell.
                    .frame(width: 22, height: 22)
                    .overlay(alignment: .topTrailing) {
                        if tab == .basket, basketCount > 0 {
                            basketBadge(basketCount)
                        }
                    }
                    .background {
                        if tab == .basket {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: BasketTabAnchorKey.self,
                                    value: geo.frame(in: .named(BasketChromeSpace.name))
                                )
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Real digits — never truncate to "…". Full count through 999; `999+` after that.
    /// `.fixedSize()` is required: the icon's 22pt frame would otherwise propose a
    /// narrow width and SwiftUI ellipsizes multi-digit badge text.
    private func basketBadge(_ count: Int) -> some View {
        Text(Self.badgeText(count))
            .font(.system(size: count >= 100 ? 9 : 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 5 : 4)
            .padding(.vertical, 2)
            .frame(minWidth: count >= 100 ? 26 : (count > 9 ? 18 : 14))
            .background(Capsule().fill(Color.red))
            .fixedSize()
            .scaleEffect(badgeScale)
            // IG-style: half off the top-trailing corner of the trash glyph.
            .offset(x: count >= 100 ? 10 : 6, y: -6)
    }

    static func badgeText(_ count: Int) -> String {
        if count >= 1000 { return "999+" }
        return "\(count)"
    }
}

extension AppTab: CaseIterable, Identifiable {
    static var allCases: [AppTab] { [.feed, .liked, .notes, .basket, .settings] }

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .feed: return "play.rectangle.fill"
        case .liked: return "heart.fill"
        case .notes: return "text.bubble.fill"
        case .basket: return "trash.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var title: String {
        switch self {
        case .feed: return String(localized: "tab.feed")
        case .liked: return String(localized: "tab.liked")
        case .notes: return String(localized: "tab.notes")
        case .basket: return String(localized: "tab.basket")
        case .settings: return String(localized: "tab.settings")
        }
    }
}
